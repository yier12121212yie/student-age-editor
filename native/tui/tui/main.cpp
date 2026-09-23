// native/tui/tui/main.cpp — backend_tui entry point.
//
// Modes:
//   backend_tui --render-check <page|all> [--width N] [--height N]
//       Headless: render a sample page to text and exit (no network). Used by
//       smoke.py and manual verification.
//   backend_tui [--url http://127.0.0.1:<port> | --port N]
//               [--agent-config <file>] [--data-root <dir>]
//       Interactive TUI against a running backend. Without an explicit target
//       the TUI self-starts backend.exe (exe dir, default port 8770) when the
//       probe fails — same policy as the GUI's BackendLauncher — and reaps it
//       on exit. An explicit --url/--port/P8_BACKEND_URL is connect-only.
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>

#ifdef _WIN32
#include <windows.h>
#else
#include <csignal>
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "app.h"
#include "p8_api.h"
#include "p8_render.h"
#include "sa_core/paths.h"

namespace {

std::string Env(const char* k) {
    const char* v = std::getenv(k);
    return v ? std::string(v) : std::string();
}

// A backend process we spawned (and must reap on exit).
struct SpawnedBackend {
    bool alive = false;
#ifdef _WIN32
    void* handle = nullptr;  // HANDLE
#else
    int pid = -1;
#endif
};

std::string PortOf(const std::string& url) {
    const auto pos = url.rfind(':');
    return pos == std::string::npos ? std::string("8770") : url.substr(pos + 1);
}

// Spawn `backend --port N` from the exe directory (editor_root == exe dir is
// how the backend resolves _cache). False when there is no backend binary
// next to us or the spawn itself failed.
bool SpawnBackend(const std::string& port, SpawnedBackend& out) {
    const std::string dir = sa_core::paths::exe_dir();
    if (dir.empty()) return false;
#ifdef _WIN32
    const std::string exe = sa_core::paths::join(dir, "backend.exe");
    if (!sa_core::paths::is_file(exe)) return false;
    // CreateProcessW: the command line is UTF-16, so an install dir under a
    // CJK path is passed intact instead of being interpreted as ANSI (GBK)
    // bytes by CreateProcessA (same trap tts.cpp hit with its encoder spawn).
    const std::wstring wexe = sa_core::paths::to_path(exe).wstring();
    const std::wstring wdir = sa_core::paths::to_path(dir).wstring();
    std::wstring cmd = L"\"" + wexe + L"\" --port " + std::wstring(port.begin(), port.end());
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                        nullptr, wdir.c_str(), &si, &pi))
        return false;
    CloseHandle(pi.hThread);
    out.handle = pi.hProcess;
    out.alive = true;
    return true;
#else
    const std::string exe = sa_core::paths::join(dir, "backend");
    if (!sa_core::paths::is_file(exe)) return false;
    const pid_t pid = ::fork();
    if (pid < 0) return false;
    if (pid == 0) {
        // Detach the child's output from our terminal: the backend's startup
        // banner would otherwise garble the TUI (the POSIX counterpart of
        // CREATE_NO_WINDOW on Windows).
        int nul = ::open("/dev/null", O_WRONLY);
        if (nul >= 0) {
            ::dup2(nul, STDOUT_FILENO);
            ::dup2(nul, STDERR_FILENO);
            if (nul > STDERR_FILENO) ::close(nul);
        }
        ::chdir(dir.c_str());
        ::execl(exe.c_str(), exe.c_str(), "--port", port.c_str(), static_cast<char*>(nullptr));
        _exit(127);
    }
    out.pid = pid;
    out.alive = true;
    return true;
#endif
}

// Best-effort reaping: graceful /api/shutdown first, then a hard kill.
void ReapBackend(SpawnedBackend& spawned, p8::BackendApi& api) {
    if (!spawned.alive) return;
    spawned.alive = false;
    api.Shutdown();
#ifdef _WIN32
    if (WaitForSingleObject(spawned.handle, 4000) == WAIT_TIMEOUT)
        TerminateProcess(spawned.handle, 0);
    CloseHandle(spawned.handle);
#else
    for (int i = 0; i < 8; ++i) {
        int st = 0;
        if (::waitpid(spawned.pid, &st, WNOHANG) == spawned.pid) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
    ::kill(spawned.pid, SIGTERM);
    int st = 0;
    for (int i = 0; i < 2; ++i) {  // SIGTERM usually lands right away
        if (::waitpid(spawned.pid, &st, WNOHANG) == spawned.pid) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
    ::kill(spawned.pid, SIGKILL);
    ::waitpid(spawned.pid, &st, 0);
#endif
}

bool ParsePage(const std::string& name, p8::Page& out) {
    // "tables" is kept as a legacy alias: the old Tables page was absorbed
    // into the browse page's left pane.
    if (name == "mods") out = p8::Page::Mods;
    else if (name == "tables" || name == "table") out = p8::Page::Table;
    else if (name == "bugfix") out = p8::Page::Bugfix;
    else if (name == "agent") out = p8::Page::Agent;
    else if (name == "plugins" || name == "plugin") out = p8::Page::Plugins;
    else if (name == "cloud") out = p8::Page::Cloud;
    else return false;
    return true;
}

p8::AgentSettings LoadAgentSettings(const std::string& config_path) {
    p8::AgentSettings s;
    if (!config_path.empty()) {
        std::ifstream in(config_path, std::ios::binary);
        if (in) {
            std::string body((std::istreambuf_iterator<char>(in)),
                             std::istreambuf_iterator<char>());
            s = p8::AgentSettingsFromJson(p8::Json::parse(body, nullptr, false));
        }
    }
    if (!Env("P8_AI_PROVIDER").empty()) s.provider = Env("P8_AI_PROVIDER");
    if (!Env("P8_AI_BASE").empty()) s.base = Env("P8_AI_BASE");
    if (!Env("P8_AI_MODEL").empty()) s.model = Env("P8_AI_MODEL");
    if (!Env("P8_AI_KEY").empty()) s.api_key = Env("P8_AI_KEY");
    if (!s.model.empty() && s.model != "gpt-4o-mini" && s.provider.empty())
        s.provider = "openai_compatible";
    return s;
}

}  // namespace

int main(int argc, char** argv) {
    std::string url = Env("P8_BACKEND_URL");
    std::string config_path;
    std::string data_root = Env("EDITOR_DATA_ROOT");
    std::string render_page;
    bool connect_probe = false;
    int width = 90, height = 24;

    bool explicit_url = false;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&](std::string& dst) {
            if (i + 1 < argc) dst = argv[++i];
        };
        if (a == "--url") { next(url); explicit_url = true; }
        else if (a == "--port") { std::string p; next(p); url = "http://127.0.0.1:" + p; explicit_url = true; }
        else if (a == "--agent-config") next(config_path);
        else if (a == "--data-root") next(data_root);
        else if (a == "--width") { std::string p; next(p); width = std::atoi(p.c_str()); }
        else if (a == "--height") { std::string p; next(p); height = std::atoi(p.c_str()); }
        else if (a == "--render-check") next(render_page);
        else if (a == "--connect") connect_probe = true;
    }
    if (url.empty()) url = "http://127.0.0.1:8770";
    else explicit_url = true;  // P8_BACKEND_URL counts as an explicit target too

    if (connect_probe) {
        p8::BackendApi api(url);
        std::string err;
        if (!api.Ping(&err)) {
            std::cerr << "PING_FAIL " << err << "\n";
            return 3;
        }
        auto mods = api.ListMods(&err);
        if (mods.empty()) {
            std::cerr << "NO_MODS " << err << "\n";
            return 4;
        }
        api.SelectMod(mods[0].name, &err);
        auto tables = api.ListTables(&err);
        long long rows = 0;
        std::string first = tables.empty() ? std::string("-") : tables[0];
        if (!tables.empty()) {
            p8::Table t;
            if (api.LoadTable(tables[0], t, &err)) rows = static_cast<long long>(t.rows.size());
        }
        std::cout << "CONNECT_OK mods=" << mods.size() << " tables=" << tables.size()
                  << " first=" << first << " rows=" << rows << "\n";
        return (!tables.empty() && rows > 0) ? 0 : 5;
    }

    if (!render_page.empty()) {
        if (render_page == "all") {
            for (const char* p : {"mods", "table", "bugfix", "agent", "plugins", "cloud"}) {
                p8::Page page;
                if (!ParsePage(p, page)) continue;
                std::cout << "==== render-check: " << p << " ====\n";
                std::cout << p8::RenderPageToString(p8::TuiApp::SampleState(page), width, height);
                std::cout << "\n";
            }
        } else {
            p8::Page page;
            if (!ParsePage(render_page, page)) {
                std::cerr << "unknown page: " << render_page << "\n";
                return 2;
            }
            std::cout << p8::RenderPageToString(p8::TuiApp::SampleState(page), width, height);
        }
        return 0;
    }

    p8::AgentSettings agent = LoadAgentSettings(config_path);
    p8::TuiApp app(url, agent, data_root);

    // 无显式目标时自起后端（显式 --url/--port/P8_BACKEND_URL 只连接不自起，
    // 以免掩盖集成测试对 PING_FAIL/连接失败路径的断言）。拉起失败不拦着进
    // 界面——状态栏的「后端未连接」仍是准确的，且 stderr 有可操作提示。
    SpawnedBackend spawned;
    p8::BackendApi reap_api(url);
    {
        std::string err;
        if (!explicit_url && !reap_api.Ping(&err)) {
            const std::string port = PortOf(url);
            std::cerr << "后端未就绪（" << err << "），尝试自起 backend --port "
                      << port << " ...\n";
            if (SpawnBackend(port, spawned)) {
                bool ready = false;
                for (int i = 0; i < 60; ++i) {  // 与 GUI 启动等待同一量级
                    std::this_thread::sleep_for(std::chrono::milliseconds(500));
                    std::string e2;
                    if (reap_api.Ping(&e2)) { ready = true; break; }
                }
                if (ready) {
                    std::cerr << "后端已就绪：" << url << "\n";
                } else {
                    std::cerr << "后端启动超时，将继续以未连接状态进入 TUI。\n";
                    ReapBackend(spawned, reap_api);
                }
            } else {
                std::cerr << "本目录未找到 backend 可执行文件。请先启动主程序"
                             "（GUI 会自动起后端，注意其端口为 8765），"
                             "或用 --port 指定已运行的后端端口。\n";
            }
        }
    }
    try {
        app.Run();
    } catch (const std::exception& e) {
        std::cerr << "TUI 运行异常: " << e.what() << "\n";
        ReapBackend(spawned, reap_api);
        return 1;
    }
    ReapBackend(spawned, reap_api);
    return 0;
}
