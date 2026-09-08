// wip/P4/p4_mock.h — header-only local HTTP mock (httplib::Server) for the
// [p4] suite. The code under test reaches it through sa_core::http (WinHTTP),
// so tests exercise the real transport + the provider byte-protocol branches
// without touching the network.
#pragma once

#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>

#include <httplib.h>

namespace p4mock {

// Owns a backgrounding httplib::Server. Attach handlers via `server` BEFORE
// start(); stop() is called on destruction.
class Server {
  public:
    int start() {
        port_ = srv_.bind_to_any_port("127.0.0.1");
        th_ = std::thread([this] { srv_.listen_after_bind(); });
        // Wait until the listener is accepting (a request returns, even a 404).
        for (int i = 0; i < 200; ++i) {
            httplib::Client cli("127.0.0.1", port_);
            cli.set_connection_timeout(0, 50000);  // 50ms
            if (cli.Get("/__ready")) { ready_ = true; break; }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        return port_;
    }
    ~Server() {
        stop();
    }
    void stop() {
        srv_.stop();
        if (th_.joinable()) th_.join();
    }
    int port() const { return port_; }
    std::string base() const { return "http://127.0.0.1:" + std::to_string(port_); }
    httplib::Server& server() { return srv_; }

  private:
    httplib::Server srv_;
    std::thread th_;
    int port_ = 0;
    bool ready_ = false;
};

}  // namespace p4mock
