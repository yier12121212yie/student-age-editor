// wip/P8/tui/app.h — the interactive FTXUI layer (only linked into backend_tui).
//
// The state machine (p8_view_model) and DOM builders (p8_render) are headless;
// this class is the thin glue that: maps ftxui::Event -> KeyInput, drives
// HandleKey, executes the returned Intent against the real backend / agent, and
// renders each frame.
#pragma once

#include <string>

#include "p8_agent.h"
#include "p8_api.h"
#include "p8_model.h"

namespace ftxui {
class ScreenInteractive;
class Event;
}  // namespace ftxui

namespace p8 {

class TuiApp {
public:
    TuiApp(std::string base_url, AgentSettings agent_settings, std::string data_root);

    // Enter the ScreenInteractive event loop; returns after Quit / Ctrl-C.
    void Run();

    AppState st;  // public so --render-check/tests can seed it

    // Build a deterministic sample state for a page (used by --render-check).
    static AppState SampleState(Page page);

    // Used by the TuiComponent (Render/OnEvent) below in app.cpp.
    int render_width() const;
    int render_list_height() const;
    void RunIntent(Intent intent);
    KeyInput MapEventPublic(const ftxui::Event& e) const;

private:
    KeyInput MapEvent(const ftxui::Event& e) const;
    void LoadMods();

    BackendApi api_;
    AgentClient agent_;
    std::string data_root_;
    bool force_save_ = false;
    std::string session_id_;
    ftxui::ScreenInteractive* screen_ = nullptr;
    int width_ = 80;
    int height_ = 24;
};

}  // namespace p8
