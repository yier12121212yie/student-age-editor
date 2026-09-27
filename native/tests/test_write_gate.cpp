// tests/test_write_gate.cpp — regression coverage for the workspace write gate
// (cfg_store::WorkspaceWriteGuard, TOCTOU hardening).
//
// Contract: the gate is a recursive mutex taken by write_cfg/apply_patch/
// undo/redo BEFORE the per-path lock, and held by revision-checked route
// handlers ACROSS "verify_revision -> write". Two properties must hold:
//   1. Re-entrancy: a handler already holding the guard may call write_cfg
//      (which re-acquires) without self-deadlock. If the gate were a plain
//      std::mutex this would hang the same way revision_manager used to.
//   2. Serialize: a concurrent writer blocked on the gate cannot interleave a
//      verify+write pair with ours (the lost-update this gate exists to kill).
#include <catch_amalgamated.hpp>

#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>

#include "sa_core/paths.h"
#include "server/cfg_store.h"
#include "test_support.h"

namespace {

namespace store = sa::cfg_store;

struct GateFixture {
    std::filesystem::path root, cfg_dir, path;
    explicit GateFixture(const std::string& tag) : root(sat::make_temp_dir(tag)) {
        cfg_dir = root / "Cfgs" / "zh-cn";
        std::filesystem::create_directories(cfg_dir);
        path = cfg_dir / "EvtCfg.json";
        {
            std::ofstream out(path, std::ios::binary | std::ios::trunc);
            out << "{\n  \"1\": {\n    \"id\": 1\n  }\n}\n";
        }
        store::debug_reset_stacks();
        store::set_parse_provider(nullptr);
    }
    ~GateFixture() {
        store::debug_reset_stacks();
        std::error_code ec;
        std::filesystem::remove_all(root, ec);
    }
    std::string p() const { return sa_core::paths::path_to_utf8(path); }
};

// write_cfg with a unique scalar at key "1" so a test can read the file back
// and assert the last writer's value survived.
void write_marker(const std::string& p, int marker) {
    store::write_cfg(p, store::json{{"1", store::json{{"id", 1}, {"v", marker}}}});
}

}  // namespace

TEST_CASE("write_gate: 外层持 guard + 内层 write_cfg 可重入，不自死锁") {
    GateFixture fx("gate_reentry");
    store::WorkspaceWriteGuard outer;
    // 路由层语义：verify(持 guard) -> write_cfg(再取同一把递归锁)。
    // 若 gate 误用非递归 std::mutex，这里会像 revision_manager 那样挂死。
    write_marker(fx.p(), 42);
    store::apply_patch(fx.p(), store::json{{"1", store::json{{"id", 1}, {"v", 43}}}},
                       store::json::array(), nullptr, std::nullopt, nullptr, false);
    // 落盘即成功：文件可读且 guard 尚未析构（离开作用域才释放）。
    auto raw = store::read_raw(fx.p());
    REQUIRE(raw.has_value());
    REQUIRE(raw->find("43") != std::string::npos);
}

TEST_CASE("write_gate: 并发写不交错，最后一个持门者的值胜出（无 lost update）") {
    GateFixture fx("gate_serial");

    std::atomic<bool> a_holding{false}, b_seen_a{false};
    std::atomic<int> done{0};

    // 线程 A：取 guard，标记已持有，写 v=100，释放。
    std::thread a([&] {
        store::WorkspaceWriteGuard g;
        a_holding.store(true);
        write_marker(fx.p(), 100);
        // 故意让 B 有机会观察到持门窗口
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        a_holding.store(false);
    });
    // 线程 B：稍后启动，尝试取 guard（会阻塞直到 A 释放）→ 写 v=200。
    std::thread b([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        store::WorkspaceWriteGuard g;  // 关键：必须等 A 的门释放
        b_seen_a.store(!a_holding.load());  // 取到门时 A 应已不再持有
        write_marker(fx.p(), 200);
        done.fetch_add(1);
    });
    a.join();
    b.join();

    REQUIRE(done.load() == 1);
    REQUIRE(b_seen_a.load());  // B 的门只在 A 释放后才拿到 → 未交错

    // 最终落盘应是 B 的 v=200（后取门者胜，符合"串行化"预期）。
    auto raw = store::read_raw(fx.p());
    REQUIRE(raw.has_value());
    REQUIRE(raw->find("200") != std::string::npos);
}

TEST_CASE("write_gate: guard 析构后锁释放，后续写不被永久阻塞") {
    GateFixture fx("gate_release");
    {
        store::WorkspaceWriteGuard g;
        write_marker(fx.p(), 7);
    }  // guard 释放
    bool ok = false;
    std::thread t([&] {
        store::WorkspaceWriteGuard g2;  // 若上块没释放门，这里挂死
        ok = true;
    });
    t.join();
    REQUIRE(ok);
}
