// tests/test_revision_manager.cpp — regression coverage for the workspace
// content fingerprint (CONVENTIONS 5.7).
//
// Why this exists: the routes call set_workspace_root() immediately before
// get_current_revision() (base_routes GET /api/workspace/revision) and before
// verify_revision() on every PUT/DELETE (cfg_routes). set_workspace_root
// always invalidates the cache, so the pre-fix compute_revision_cached() took
// g_revision_mu and then called compute_revision(), which re-locked the SAME
// non-recursive std::mutex — a self-deadlock on EVERY save-flow revision
// call. A stuck connection thread also pins the mutex for all other routes,
// so the whole local API degrades toward slot exhaustion.
//
// If the lock boundary regresses, the guarded cases fail via timeout instead
// of hanging sa_tests forever (stuck threads are detached and die at process
// exit).
#include <catch_amalgamated.hpp>

#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <future>
#include <functional>
#include <string>
#include <thread>

#include "server/revision_manager.h"
#include "test_support.h"

namespace {

namespace rm = sa::revision_manager;
using namespace std::chrono_literals;

void write_file(const std::filesystem::path& p, const std::string& content) {
    std::filesystem::create_directories(p.parent_path());
    std::ofstream out(p, std::ios::binary | std::ios::trunc);
    out << content;
}

struct RevFixture {
    std::filesystem::path root;
    explicit RevFixture(const std::string& tag) : root(sat::make_temp_dir(tag)) {
        write_file(root / "Cfgs" / "zh-cn" / "TalkCfg.json", R"({"id":"t1"})");
        write_file(root / "Cfgs" / "zh-cn" / "EvtCfg.json", R"({"id":"e1"})");
        write_file(root / "manifest.json", R"({"name":"demo"})");
    }
};

// 在独立线程执行 fn，超时即返回 false（回归死锁时给出断言而非挂死整组测试）。
template <class R>
bool call_within(const std::function<R()>& fn, R* out, std::chrono::milliseconds ms) {
    auto pr = std::make_shared<std::promise<R>>();
    auto fut = pr->get_future();
    std::thread([pr, fn]() {
        try {
            pr->set_value(fn());
        } catch (...) {
            pr->set_exception(std::current_exception());
        }
    }).detach();
    if (fut.wait_for(ms) != std::future_status::ready) return false;
    if (out) *out = fut.get();
    return true;
}

}  // namespace

TEST_CASE("revision_manager: set→get→verify 往返不挂起且指纹正确") {
    RevFixture fx("rev_basic");
    rm::set_workspace_root(fx.root.string());

    std::string rev;
    // 修复前这两个调用（缓存被 set_workspace_root 强制失效 → force 重算 →
    // 重复加锁）无条件死锁，必须走超时护栏。
    REQUIRE(call_within<std::string>([] { return rm::get_current_revision(); }, &rev, 10s));
    REQUIRE_FALSE(rev.empty());
    REQUIRE(rev.size() == 20);

    bool ok = false;
    REQUIRE(call_within<bool>([rev] { return rm::verify_revision(rev); }, &ok, 10s));
    REQUIRE(ok);

    // 内容变化 → 旧 revision 校验失败，重算得到新指纹（此处路径已无死锁，直接调用）。
    write_file(fx.root / "Cfgs" / "zh-cn" / "TalkCfg.json", R"({"id":"t2"})");
    REQUIRE_FALSE(rm::verify_revision(rev));
    REQUIRE(rm::get_current_revision() != rev);
}

TEST_CASE("revision_manager: unchanged files reuse the fingerprint cache") {
    RevFixture fx("rev_cache");
    const std::string root = fx.root.string();
    rm::set_workspace_root(root);
    REQUIRE_FALSE(rm::get_current_revision().empty());
    CHECK(rm::debug_files_scanned_count() == 3);   // TalkCfg + EvtCfg + manifest
    CHECK(rm::debug_files_hashed_count() == 3);

    // Fresh scan with no content change: everything comes from the cache.
    rm::set_workspace_root(root);
    REQUIRE_FALSE(rm::get_current_revision().empty());
    CHECK(rm::debug_files_scanned_count() == 3);
    CHECK(rm::debug_files_hashed_count() == 0);

    // A changed file forces exactly that one file to be re-hashed.
    rm::set_workspace_root(root);
    write_file(fx.root / "Cfgs" / "zh-cn" / "TalkCfg.json", R"({"id":"t9"})");
    REQUIRE_FALSE(rm::get_current_revision().empty());
    CHECK(rm::debug_files_hashed_count() == 1);
}

TEST_CASE("revision_manager: 空 root 与空 client_revision 的边界") {
    rm::set_workspace_root("");
    REQUIRE(rm::get_current_revision().empty());
    REQUIRE_FALSE(rm::verify_revision("anything"));

    RevFixture fx("rev_empty_client");
    rm::set_workspace_root(fx.root.string());
    REQUIRE_FALSE(rm::verify_revision(""));  // 客户端没带 revision 不得放行
}

TEST_CASE("revision_manager: 并发 set/get/verify（保存链路压力）不挂起") {
    RevFixture fx("rev_conc");
    const std::string root = fx.root.string();

    constexpr int kThreads = 4;
    constexpr int kIters = 120;
    std::atomic<int> completed{0};
    for (int i = 0; i < kThreads; ++i) {
        std::thread([&completed, root] {
            for (int n = 0; n < kIters; ++n) {
                rm::set_workspace_root(root);
                std::string rev = rm::get_current_revision();
                rm::verify_revision(rev);
                rm::verify_revision("stale-hash");
                completed.fetch_add(1, std::memory_order_relaxed);
            }
        }).detach();
    }

    const auto deadline = std::chrono::steady_clock::now() + 30s;
    while (completed.load(std::memory_order_relaxed) < kThreads * kIters &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(20ms);
    }
    REQUIRE(completed.load() == kThreads * kIters);
}
