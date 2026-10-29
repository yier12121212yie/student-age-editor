// native/tui/tui/app.h — the interactive FTXUI layer (only linked into backend_tui).
//
// The state machine (p8_view_model) and DOM builders (p8_render) are headless;
// this class is the thin glue that: maps ftxui::Event -> KeyInput, drives
// HandleKey, executes the returned Intent against the real backend / agent, and
// renders each frame.
//
// Intents run on a background worker so the UI never freezes on a slow backend
// or a 120s AI round-trip: while one runs, the keyboard is swallowed (Esc raises
// the cancel flag) and the renderer shows a snapshot taken at dispatch time, so
// the main thread never touches AppState concurrently with the worker. The
// worker hands the updated state back through a posted completion event.
#pragma once

#include <atomic>
#include <mutex>
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

    // ---- async intent plumbing (used by TuiComponent in app.cpp) ------------
    // True while a background intent is executing: the keyboard is frozen
    // (Esc cancels chat, everything else waits) and the renderer shows the
    // snapshot taken at dispatch time, so the main thread never touches `st`
    // concurrently with the worker.
    bool busy() const { return busy_.load(std::memory_order_acquire); }
    const AppState& render_state() const { return busy() ? st_view : st; }
    // Snapshot st into st_view and run `intent` on a worker thread, showing
    // busy_text in the status bar. For quick intents the worker mutates st
    // directly (the main thread is frozen meanwhile).
    void DispatchAsync(Intent intent, const std::string& busy_text);
    // The AI chat runs on a private copy so Esc can abandon it immediately;
    // the finished copy is handed back through AdoptCompletion.
    void DispatchChat();
    // True between a dispatch and its completion event being consumed.
    bool completion_pending() const { return completion_pending_; }
    // Main thread, on the completion event: adopt the worker's result.
    void AdoptCompletion();
    // Esc while a chat is running: roll back to the dispatch snapshot at once;
    // the worker's late result is discarded.
    void CancelChat();
    bool chat_busy_running() const { return is_chat_busy_.load(std::memory_order_acquire); }

private:
    KeyInput MapEvent(const ftxui::Event& e) const;
    void LoadMods();
    // One-shot startup probe+seed that runs on the worker before the first
    // interactive frame (Ping → mods/flags/schema in parallel → OOBE).
    void RunStartupSequence(AppState& s);

    BackendApi api_;
    AgentClient agent_;
    std::string data_root_;
    std::atomic<bool> force_save_{false};
    std::string session_id_;
    ftxui::ScreenInteractive* screen_ = nullptr;

    std::atomic<bool> busy_{false};
    std::atomic<bool> is_chat_busy_{false};
    std::atomic<bool> chat_abandoned_{false};
    std::atomic<long long> chat_epoch_{0};
    bool completion_pending_ = false;  // main thread only
    AppState st_view;   // rendered while busy (owned by the main thread)
    AppState st_done;   // chat worker's finished copy (guarded by done_mu_)
    std::mutex done_mu_;
};

}  // namespace p8
