// server/services/mcp_bridge.cpp — see mcp_bridge.h.
//
// 一个后端实例持有最多 kMaxSessions 个 stdio MCP 子进程；每个进程一条
// stdout reader 线程把行分隔 JSON-RPC 推进队列，SSE 端点把队列转成
// `data: <json>` 帧。子进程的 stderr 丢弃（MCP 协议只用 stdout）。
#include "mcp_bridge.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/util.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace sa {
namespace mcp_bridge {
namespace {

constexpr size_t kMaxSessions = 8;
constexpr size_t kMaxQueuedLines = 512;
constexpr size_t kMaxLineBytes = 4u * 1024 * 1024;
constexpr long long kIdleMs = 10LL * 60 * 1000;

struct Session {
    std::string id;
    std::string command;
    std::vector<std::string> argv;
    long long last_used_ms = 0;

#ifdef _WIN32
    HANDLE proc = nullptr;
    HANDLE stdin_w = nullptr;
    HANDLE stdout_r = nullptr;
#else
    pid_t pid = -1;
    int stdin_w = -1;
    int stdout_r = -1;
#endif

    std::thread reader;
    std::mutex write_mu;
    std::mutex mu;
    std::condition_variable cv;
    std::deque<std::string> lines;
    bool closed = false;
};

std::mutex g_mu;
std::unordered_map<std::string, std::shared_ptr<Session>> g_sessions;

bool hosted_mode() {
    return !sa_core::paths::getenv_utf8("EDITOR_HOSTED").empty();
}

std::vector<std::string> allow_list() {
    std::vector<std::string> out;
    const std::string raw = sa_core::paths::getenv_utf8("EDITOR_MCP_STDIO_ALLOW");
    size_t start = 0;
    while (start <= raw.size()) {
        const size_t comma = raw.find(',', start);
        std::string item = sa_core::str::trim(
            raw.substr(start, comma == std::string::npos ? std::string::npos : comma - start));
        if (!item.empty()) out.push_back(item);
        if (comma == std::string::npos) break;
        start = comma + 1;
    }
    return out;
}

bool bridge_available() { return !hosted_mode() || !allow_list().empty(); }

std::string base_name(const std::string& cmd) {
    const size_t slash = cmd.find_last_of("/\\");
    return slash == std::string::npos ? cmd : cmd.substr(slash + 1);
}

bool command_allowed(const std::string& command) {
    if (!hosted_mode()) return true;
    const auto list = allow_list();
    if (list.empty()) return false;
    const std::string base = base_name(command);
    for (const auto& item : list) {
        if (item == command || item == base) return true;
    }
    return false;
}

std::string new_session_id() {
    static std::atomic<unsigned long long> counter{0};
    static const char* hexd = "0123456789abcdef";
    static std::mt19937_64 rng(static_cast<unsigned long long>(std::random_device{}()) ^
                               static_cast<unsigned long long>(sa_core::now_ms()) ^
                               counter.fetch_add(0x9E3779B97F4A7C15ull));
    std::string out;
    out.reserve(32);
    for (int i = 0; i < 32; ++i) out += hexd[(rng() >> ((i % 16) * 4)) & 0xF];
    return out;
}

// ---------------------------------------------------------------------------
// 子进程输出读取：按 '\n' 切行，忽略空行/超长行；EOF 时置 closed。
// ---------------------------------------------------------------------------
void reader_loop(Session* s) {
    std::string buf;
    buf.reserve(8192);
#ifdef _WIN32
    char chunk[4096];
    for (;;) {
        DWORD got = 0;
        if (!ReadFile(s->stdout_r, chunk, sizeof(chunk), &got, nullptr) || got == 0) break;
        buf.append(chunk, got);
        for (;;) {
            const size_t nl = buf.find('\n');
            if (nl == std::string::npos) break;
            std::string line = buf.substr(0, nl);
            buf.erase(0, nl + 1);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty()) continue;
            std::lock_guard<std::mutex> lk(s->mu);
            if (s->lines.size() >= kMaxQueuedLines) s->lines.pop_front();
            s->lines.push_back(std::move(line));
            s->cv.notify_all();
        }
        if (buf.size() > kMaxLineBytes) buf.clear();  // 丢弃异常长行
    }
#else
    char chunk[4096];
    for (;;) {
        const ssize_t got = ::read(s->stdout_r, chunk, sizeof(chunk));
        if (got < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (got == 0) break;
        buf.append(chunk, static_cast<size_t>(got));
        for (;;) {
            const size_t nl = buf.find('\n');
            if (nl == std::string::npos) break;
            std::string line = buf.substr(0, nl);
            buf.erase(0, nl + 1);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty()) continue;
            std::lock_guard<std::mutex> lk(s->mu);
            if (s->lines.size() >= kMaxQueuedLines) s->lines.pop_front();
            s->lines.push_back(std::move(line));
            s->cv.notify_all();
        }
        if (buf.size() > kMaxLineBytes) buf.clear();
    }
#endif
    // 把最后一段没有换行的输出也交付（部分服务器收尾时不写 '\n'）。
    if (!buf.empty()) {
        if (buf.back() == '\r') buf.pop_back();
        std::lock_guard<std::mutex> lk(s->mu);
        if (!buf.empty()) s->lines.push_back(std::move(buf));
    }
    {
        std::lock_guard<std::mutex> lk(s->mu);
        s->closed = true;
        s->cv.notify_all();
    }
}

void close_session(const std::shared_ptr<Session>& s) {
    if (!s) return;
#ifdef _WIN32
    {
        std::lock_guard<std::mutex> lk(s->write_mu);
        if (s->stdin_w) {
            CloseHandle(s->stdin_w);
            s->stdin_w = nullptr;
        }
    }
    if (s->proc) {
        TerminateProcess(s->proc, 1);
        WaitForSingleObject(s->proc, 3000);
    }
    if (s->reader.joinable()) s->reader.join();
    if (s->stdout_r) {
        CloseHandle(s->stdout_r);
        s->stdout_r = nullptr;
    }
    if (s->proc) {
        CloseHandle(s->proc);
        s->proc = nullptr;
    }
#else
    {
        std::lock_guard<std::mutex> lk(s->write_mu);
        if (s->stdin_w >= 0) {
            ::close(s->stdin_w);
            s->stdin_w = -1;
        }
    }
    if (s->pid > 0) {
        ::kill(s->pid, SIGTERM);
        for (int i = 0; i < 20; ++i) {
            int status = 0;
            const pid_t r = ::waitpid(s->pid, &status, WNOHANG);
            if (r == s->pid || r < 0) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        ::kill(s->pid, SIGKILL);
        int status = 0;
        ::waitpid(s->pid, &status, 0);
        s->pid = -1;
    }
    if (s->reader.joinable()) s->reader.join();
    if (s->stdout_r >= 0) {
        ::close(s->stdout_r);
        s->stdout_r = -1;
    }
#endif
    {
        std::lock_guard<std::mutex> lk(s->mu);
        s->closed = true;
        s->cv.notify_all();
    }
}

// 调用方必须持有 g_mu。
void sweep_locked(long long now) {
    for (auto it = g_sessions.begin(); it != g_sessions.end();) {
        if (now - it->second->last_used_ms > kIdleMs) {
            close_session(it->second);
            it = g_sessions.erase(it);
        } else {
            ++it;
        }
    }
}

// ---------------------------------------------------------------------------
// 进程启动
// ---------------------------------------------------------------------------
#ifdef _WIN32
std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                                      nullptr, 0);
    std::wstring out(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
    return out;
}

std::wstring quote_arg(const std::string& arg) {
    const std::wstring a = widen(arg);
    std::wstring out;
    out.push_back(L'"');
    size_t backslashes = 0;
    for (wchar_t c : a) {
        if (c == L'\\') {
            ++backslashes;
            continue;
        }
        if (c == L'"') {
            out.append(backslashes * 2 + 1, L'\\');
            out.push_back(L'"');
        } else {
            out.append(backslashes, L'\\');
            out.push_back(c);
        }
        backslashes = 0;
    }
    out.append(backslashes * 2, L'\\');
    out.push_back(L'"');
    return out;
}

// 只在必要时加引号。cmd.exe 对 /c 的后续内容有自己的去引号规则：
// `cmd "/c" "echo hi"` 会被拼成 `/c" "echo hi` 而报「语法不正确」，
// 而 `cmd /c "echo hi"` 正常——所以 /c 这类开关必须保持裸写。
std::wstring quote_arg_if_needed(const std::string& arg) {
    if (arg.empty() || arg.find_first_of(" \t\"") != std::string::npos)
        return quote_arg(arg);
    return widen(arg);
}
#endif

bool spawn_session(const std::shared_ptr<Session>& s, std::string* err) {
#ifdef _WIN32
    auto make_pipe = [](HANDLE& rd, HANDLE& wr) {
        SECURITY_ATTRIBUTES sa{};
        sa.nLength = sizeof(sa);
        sa.bInheritHandle = TRUE;
        return CreatePipe(&rd, &wr, &sa, 0) != 0;
    };
    HANDLE in_r = nullptr, in_w = nullptr, out_r = nullptr, out_w = nullptr;
    if (!make_pipe(in_r, in_w) || !make_pipe(out_r, out_w)) {
        if (in_r) CloseHandle(in_r);
        if (in_w) CloseHandle(in_w);
        if (out_r) CloseHandle(out_r);
        if (out_w) CloseHandle(out_w);
        *err = "cannot create pipes";
        return false;
    }
    SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
    HANDLE nul_w = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                               nullptr, OPEN_EXISTING, 0, nullptr);

    // 程序名与参数都只在必要时加引号（见 quote_arg_if_needed）：Windows 上
    // 最常见的 MCP 包装 `cmd /c <命令>` 依赖 /c 保持裸写。
    std::wstring cmdline = quote_arg_if_needed(s->command);
    for (const auto& a : s->argv) {
        cmdline.push_back(L' ');
        cmdline += quote_arg_if_needed(a);
    }
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_r;
    si.hStdOutput = out_w;
    si.hStdError = nul_w ? nul_w : out_w;
    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> cbuf(cmdline.begin(), cmdline.end());
    cbuf.push_back(L'\0');
    const BOOL ok = CreateProcessW(nullptr, cbuf.data(), nullptr, nullptr, TRUE,
                                   CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    CloseHandle(in_r);
    CloseHandle(out_w);
    if (nul_w) CloseHandle(nul_w);
    if (!ok) {
        CloseHandle(in_w);
        CloseHandle(out_r);
        *err = "CreateProcess failed (" + std::to_string(GetLastError()) + ")";
        return false;
    }
    CloseHandle(pi.hThread);
    s->proc = pi.hProcess;
    s->stdin_w = in_w;
    s->stdout_r = out_r;
#else
    int in_pipe[2], out_pipe[2];
    if (::pipe(in_pipe) != 0) {
        *err = "cannot create stdin pipe";
        return false;
    }
    if (::pipe(out_pipe) != 0) {
        ::close(in_pipe[0]);
        ::close(in_pipe[1]);
        *err = "cannot create stdout pipe";
        return false;
    }
    std::vector<std::string> argv_storage;
    argv_storage.push_back(s->command);
    for (const auto& a : s->argv) argv_storage.push_back(a);
    std::vector<char*> argv;
    for (auto& a : argv_storage) argv.push_back(const_cast<char*>(a.c_str()));
    argv.push_back(nullptr);

    const pid_t pid = ::fork();
    if (pid < 0) {
        ::close(in_pipe[0]);
        ::close(in_pipe[1]);
        ::close(out_pipe[0]);
        ::close(out_pipe[1]);
        *err = "fork failed";
        return false;
    }
    if (pid == 0) {
        ::setsid();
        ::dup2(in_pipe[0], STDIN_FILENO);
        ::dup2(out_pipe[1], STDOUT_FILENO);
        const int nul = ::open("/dev/null", O_WRONLY);
        if (nul >= 0) ::dup2(nul, STDERR_FILENO);
        ::close(in_pipe[0]);
        ::close(in_pipe[1]);
        ::close(out_pipe[0]);
        ::close(out_pipe[1]);
        ::execvp(argv[0], argv.data());
        ::_exit(127);
    }
    ::close(in_pipe[0]);
    ::close(out_pipe[1]);
    s->pid = pid;
    s->stdin_w = in_pipe[1];
    s->stdout_r = out_pipe[0];
#endif
    s->last_used_ms = sa_core::now_ms();
    s->reader = std::thread(reader_loop, s.get());
    return true;
}

bool write_line(const std::shared_ptr<Session>& s, const std::string& line, std::string* err) {
    const std::string data = line + "\n";
    std::lock_guard<std::mutex> lk(s->write_mu);
#ifdef _WIN32
    if (!s->stdin_w) {
        *err = "session closed";
        return false;
    }
    size_t off = 0;
    while (off < data.size()) {
        DWORD written = 0;
        const DWORD chunk = static_cast<DWORD>(
            std::min<size_t>(data.size() - off, 1u << 20));
        if (!WriteFile(s->stdin_w, data.data() + off, chunk, &written, nullptr) ||
            written == 0) {
            *err = "write failed";
            return false;
        }
        off += written;
    }
#else
    if (s->stdin_w < 0) {
        *err = "session closed";
        return false;
    }
    size_t off = 0;
    while (off < data.size()) {
        const ssize_t n = ::write(s->stdin_w, data.data() + off, data.size() - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            *err = "write failed";
            return false;
        }
        if (n == 0) {
            *err = "write failed";
            return false;
        }
        off += static_cast<size_t>(n);
    }
#endif
    return true;
}

std::string body_str(const json& body, const char* key) {
    if (!body.is_object() || !body.contains(key) || body.at(key).is_null()) return "";
    return body.at(key).is_string() ? body.at(key).get<std::string>()
                                    : sa_core::py_str(body.at(key));
}

}  // namespace

void register_mcp_bridge_routes(Router& r) {
    // GET /api/mcp/stdio/policy —— 前端据此决定是否展示 stdio 表单。
    r.get(R"(/api/mcp/stdio/policy)", [](const Req&) -> Resp {
        json out = json::object();
        out["available"] = bridge_available();
        out["hosted"] = hosted_mode();
        json allow = json::array();
        if (hosted_mode()) {
            for (const auto& a : allow_list()) allow.push_back(a);
        }
        out["allow"] = std::move(allow);
        return Resp::Json(200, std::move(out));
    });

    // POST /api/mcp/stdio/start {command,args[]} -> {session_id}
    r.post(R"(/api/mcp/stdio/start)", [](const Req& req) -> Resp {
        if (!bridge_available())
            return Resp::Json(
                403, json{{"error", "mcp stdio bridge disabled in hosted mode"}});
        const json& body = req.body;
        if (!body.is_object())
            return Resp::Json(400, json{{"error", "body must be a JSON object"}});
        std::string command = sa_core::str::trim(body_str(body, "command"));
        if (command.empty())
            return Resp::Json(400, json{{"error", "command required"}});
        if (command.size() > 1024)
            return Resp::Json(400, json{{"error", "command too long"}});
        if (!command_allowed(command))
            return Resp::Json(403, json{{"error", "command not allowed: " + command}});

        std::vector<std::string> args;
        if (body.contains("args")) {
            if (!body.at("args").is_array())
                return Resp::Json(
                    400, json{{"error", "args must be an array of strings"}});
            if (body.at("args").size() > 64)
                return Resp::Json(400, json{{"error", "too many args"}});
            for (const auto& v : body.at("args")) {
                if (!v.is_string())
                    return Resp::Json(400, json{{"error", "args must be strings"}});
                const std::string a = v.get<std::string>();
                if (a.size() > 4096)
                    return Resp::Json(400, json{{"error", "arg too long"}});
                args.push_back(a);
            }
        }

        auto session = std::make_shared<Session>();
        session->id = new_session_id();
        session->command = command;
        session->argv = std::move(args);
        {
            std::lock_guard<std::mutex> lk(g_mu);
            sweep_locked(sa_core::now_ms());
            if (g_sessions.size() >= kMaxSessions)
                return Resp::Json(429, json{{"error", "too many MCP sessions"}});
        }
        std::string err;
        if (!spawn_session(session, &err))
            return Resp::Json(400, json{{"error", "cannot start process: " + err}});
        {
            std::lock_guard<std::mutex> lk(g_mu);
            g_sessions[session->id] = session;
        }
        return Resp::Json(200, json{{"session_id", session->id}});
    });

    // POST /api/mcp/stdio/send {session_id,message} -> {ok}
    r.post(R"(/api/mcp/stdio/send)", [](const Req& req) -> Resp {
        const std::string id = body_str(req.body, "session_id");
        if (id.empty()) return Resp::Json(400, json{{"error", "session_id required"}});
        if (!req.body.is_object() || !req.body.contains("message") ||
            !req.body.at("message").is_object())
            return Resp::Json(400, json{{"error", "message must be a JSON-RPC object"}});
        std::shared_ptr<Session> session;
        {
            std::lock_guard<std::mutex> lk(g_mu);
            auto it = g_sessions.find(id);
            if (it == g_sessions.end())
                return Resp::Json(404, json{{"error", "no such session"}});
            session = it->second;
            session->last_used_ms = sa_core::now_ms();
        }
        {
            std::lock_guard<std::mutex> lk(session->mu);
            if (session->closed)
                return Resp::Json(410, json{{"error", "session closed"}});
        }
        std::string line = sa_core::py_dumps(req.body.at("message"));
        for (char& c : line) {
            if (c == '\n' || c == '\r') c = ' ';  // 行分隔协议：单行一条
        }
        std::string err;
        if (!write_line(session, line, &err))
            return Resp::Json(410, json{{"error", err}});
        return Resp::Json(200, json{{"ok", true}});
    });

    // POST /api/mcp/stdio/stop {session_id} -> {ok}
    r.post(R"(/api/mcp/stdio/stop)", [](const Req& req) -> Resp {
        const std::string id = body_str(req.body, "session_id");
        std::shared_ptr<Session> session;
        {
            std::lock_guard<std::mutex> lk(g_mu);
            auto it = g_sessions.find(id);
            if (it != g_sessions.end()) {
                session = it->second;
                g_sessions.erase(it);
            }
        }
        if (session) close_session(session);
        return Resp::Json(200, json{{"ok", true}});
    });

    // GET /api/mcp/stdio/stream?session_id=... —— 长连接 SSE。
    r.get(R"(/api/mcp/stdio/stream)", [](const Req& req) -> Resp {
        std::string id;
        auto q = req.query.find("session_id");
        if (q != req.query.end()) id = q->second;
        if (id.empty()) return Resp::Json(400, json{{"error", "session_id required"}});
        std::shared_ptr<Session> session;
        {
            std::lock_guard<std::mutex> lk(g_mu);
            auto it = g_sessions.find(id);
            if (it == g_sessions.end())
                return Resp::Json(404, json{{"error", "no such session"}});
            session = it->second;
            session->last_used_ms = sa_core::now_ms();
        }
        Resp out;
        out.content_type = "text/event-stream";
        out.cache_control = "no-store";
        out.body_stream = [session](StreamEmitter& emitter) -> bool {
            if (!emitter.start(200, "text/event-stream")) return false;
            for (;;) {
                std::deque<std::string> batch;
                bool closed = false;
                {
                    std::unique_lock<std::mutex> lk(session->mu);
                    session->last_used_ms = sa_core::now_ms();
                    session->cv.wait_for(
                        lk, std::chrono::seconds(15),
                        [&] { return !session->lines.empty() || session->closed; });
                    batch.swap(session->lines);
                    closed = session->closed;
                }
                for (const auto& line : batch) {
                    std::string frame = "data: ";
                    frame += line;
                    frame += "\n\n";
                    if (!emitter.write(frame)) return false;
                }
                if (closed && batch.empty()) break;
                if (batch.empty() && !emitter.write(": ping\n\n")) return false;
            }
            return true;
        };
        return out;
    });
}

void shutdown_all_for_test() {
    std::vector<std::shared_ptr<Session>> all;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        for (auto& kv : g_sessions) all.push_back(kv.second);
        g_sessions.clear();
    }
    for (auto& s : all) close_session(s);
}

}  // namespace mcp_bridge
}  // namespace sa
