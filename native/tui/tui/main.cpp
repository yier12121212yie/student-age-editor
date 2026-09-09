// native/tui/tui/main.cpp — backend_tui entry point.
//
// Modes:
//   backend_tui --render-check <page|all> [--width N] [--height N]
//       Headless: render a sample page to text and exit (no network). Used by
//       smoke.py and manual verification.
//   backend_tui [--url http://127.0.0.1:<port> | --port N]
//               [--agent-config <file>] [--data-root <dir>]
//       Interactive TUI against a running backend.
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>

#include "app.h"
#include "p8_api.h"
#include "p8_render.h"

namespace {

std::string Env(const char* k) {
    const char* v = std::getenv(k);
    return v ? std::string(v) : std::string();
}

bool ParsePage(const std::string& name, p8::Page& out) {
    if (name == "mods") out = p8::Page::Mods;
    else if (name == "tables") out = p8::Page::Tables;
    else if (name == "table") out = p8::Page::Table;
    else if (name == "bugfix") out = p8::Page::Bugfix;
    else if (name == "agent") out = p8::Page::Agent;
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

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&](std::string& dst) {
            if (i + 1 < argc) dst = argv[++i];
        };
        if (a == "--url") next(url);
        else if (a == "--port") { std::string p; next(p); url = "http://127.0.0.1:" + p; }
        else if (a == "--agent-config") next(config_path);
        else if (a == "--data-root") next(data_root);
        else if (a == "--width") { std::string p; next(p); width = std::atoi(p.c_str()); }
        else if (a == "--height") { std::string p; next(p); height = std::atoi(p.c_str()); }
        else if (a == "--render-check") next(render_page);
        else if (a == "--connect") connect_probe = true;
    }
    if (url.empty()) url = "http://127.0.0.1:8770";

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
            for (const char* p : {"mods", "tables", "table", "bugfix", "agent"}) {
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
    try {
        app.Run();
    } catch (const std::exception& e) {
        std::cerr << "TUI 运行异常: " << e.what() << "\n";
        return 1;
    }
    return 0;
}
