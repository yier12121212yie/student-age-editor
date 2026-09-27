#include "server/jobs.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <random>
#include <thread>

namespace sa {
namespace jobs {
namespace {

constexpr auto kDoneTtl = std::chrono::minutes(15);
constexpr size_t kMaxJobs = 512;

struct Job {
    std::function<Resp()> fn;
    std::string id;
    enum class St { Queued, Running, Done } st = St::Queued;
    Resp resp;                                        // St::Done 时有效
    std::chrono::steady_clock::time_point expires{};  // Done 起保留 kDoneTtl
};

struct Pool {
    std::mutex mu;
    std::condition_variable cv;
    std::deque<std::string> queue;   // 待跑 id（FIFO）
    std::map<std::string, Job> jobs;  // 全量任务（含已完成）
    std::vector<std::thread> workers;
    bool stopping = false;
};

Pool& pool() {
    static Pool p;
    return p;
}

// 128-bit 随机 job id（32 hex）。每次调用新建 RNG（随机数质量对本用途足够，
// 128-bit 空间下碰撞可忽略；MinGW random_device 的退化由熵混合兜住）。
std::string new_id() {
    static std::atomic<unsigned long long> counter{0};
    static const char* hexd = "0123456789abcdef";
    std::mt19937_64 rng(
        std::random_device{}() ^
        static_cast<unsigned long long>(
            std::chrono::steady_clock::now().time_since_epoch().count()) ^
        counter.fetch_add(0x9E3779B97F4A7C15ull));
    std::string out;
    out.reserve(32);
    for (int i = 0; i < 32; ++i) out += hexd[(rng() >> ((i % 16) * 4)) & 0xF];
    return out;
}

// 惰性清理：仅在任务表超上限时扫一遍，先丢过期完成项，再丢最老完成项。
// 未完成条目永不淘汰（正在跑的任务被删等于丢结果）。
void prune_locked(Pool& p) {
    if (p.jobs.size() <= kMaxJobs) return;
    auto now = std::chrono::steady_clock::now();
    for (auto it = p.jobs.begin(); it != p.jobs.end();) {
        if (it->second.st == Job::St::Done && it->second.expires <= now)
            it = p.jobs.erase(it);
        else
            ++it;
    }
    while (p.jobs.size() > kMaxJobs) {
        auto oldest = p.jobs.end();
        for (auto it = p.jobs.begin(); it != p.jobs.end(); ++it) {
            if (it->second.st != Job::St::Done) continue;
            if (oldest == p.jobs.end() || it->second.expires < oldest->second.expires)
                oldest = it;
        }
        if (oldest == p.jobs.end()) break;
        p.jobs.erase(oldest);
    }
}

void worker_loop() {
    Pool& p = pool();
    for (;;) {
        std::string id;
        {
            std::unique_lock<std::mutex> lk(p.mu);
            p.cv.wait(lk, [&] { return p.stopping || !p.queue.empty(); });
            if (p.stopping) return;
            id = p.queue.front();
            p.queue.pop_front();
        }
        std::function<Resp()> fn;
        {
            std::lock_guard<std::mutex> lk(p.mu);
            auto it = p.jobs.find(id);
            if (it == p.jobs.end() || it->second.st != Job::St::Queued) continue;
            it->second.st = Job::St::Running;
            fn = it->second.fn;
        }
        Resp r;
        try {
            r = fn();
        } catch (const std::exception& e) {
            r = Resp::Json(500, json{{"error", std::string("RuntimeError: ") + e.what()}});
        } catch (...) {
            r = Resp::Json(500, json{{"error", "RuntimeError: unknown job failure"}});
        }
        {
            std::lock_guard<std::mutex> lk(p.mu);
            auto it = p.jobs.find(id);
            if (it != p.jobs.end()) {
                it->second.resp = std::move(r);
                it->second.st = Job::St::Done;
                it->second.expires = std::chrono::steady_clock::now() + kDoneTtl;
                prune_locked(p);
            }
        }
    }
}

}  // namespace

void start(int workers) {
    Pool& p = pool();
    std::lock_guard<std::mutex> lk(p.mu);
    if (!p.workers.empty()) return;
    for (int i = 0; i < workers; ++i) p.workers.emplace_back(worker_loop);
}

void stop() {
    Pool& p = pool();
    {
        std::lock_guard<std::mutex> lk(p.mu);
        p.stopping = true;
    }
    p.cv.notify_all();
    std::vector<std::thread> ws;
    {
        std::lock_guard<std::mutex> lk(p.mu);
        ws.swap(p.workers);
    }
    for (auto& t : ws) {
        if (t.joinable()) t.join();
    }
}

std::string submit(std::function<Resp()> fn) {
    Pool& p = pool();
    std::string id = new_id();
    {
        std::lock_guard<std::mutex> lk(p.mu);
        Job j;
        j.id = id;
        j.fn = std::move(fn);
        p.jobs[id] = std::move(j);
        p.queue.push_back(id);
        prune_locked(p);
    }
    p.cv.notify_one();
    return id;
}

bool fetch(const std::string& id, Resp* out) {
    Pool& p = pool();
    std::lock_guard<std::mutex> lk(p.mu);
    auto it = p.jobs.find(id);
    if (it == p.jobs.end()) return false;
    const Job& j = it->second;
    if (j.st != Job::St::Done) {
        *out = Resp::Json(200, json{{"status", j.st == Job::St::Queued ? "queued" : "running"},
                                    {"job_id", id}});
        return true;
    }
    if (j.resp.is_bytes) {
        *out = j.resp;
        return true;
    }
    if (j.resp.status >= 400) {
        const json& pl = j.resp.json_payload;
        std::string msg = pl.is_object() && pl.contains("error") && pl["error"].is_string()
                              ? pl["error"].get<std::string>()
                              : "HTTP " + std::to_string(j.resp.status);
        *out = Resp::Json(200, json{{"status", "error"},
                                    {"error", msg},
                                    {"status_code", j.resp.status}});
        return true;
    }
    *out = Resp::Json(200, json{{"status", "done"}, {"result", j.resp.json_payload}});
    return true;
}

}  // namespace jobs

// ---------------------------------------------------------------------------
// wrap_async_job（声明于 httpd.h 的 namespace sa；实现在这里是因为信封语义
// 与 jobs 表同源。注意它在 sa 层而非 sa::jobs——调用方直接裸名使用）。
// ---------------------------------------------------------------------------
Handler wrap_async_job(Handler fn) {
    return [fn = std::move(fn)](const Req& req) -> Resp {
        if (req.query.find("async") == req.query.end()) return fn(req);
        Req copy = req;  // json/params/headers 均为值成员；深拷贝随任务入队
        std::string id = jobs::submit([fn, copy = std::move(copy)] { return fn(copy); });
        return Resp::Json(202, json{{"job_id", id}});
    };
}

}  // namespace sa
