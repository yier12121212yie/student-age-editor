#include "sa_core/env_store.h"

#include <map>
#include <memory>
#include <mutex>

#include "sa_core/atomic_io.h"
#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "sa_core/strings.h"
#include "sa_core/utf8.h"

namespace sa_core {
namespace env_store {
namespace {

std::string strip_ws(const std::string& s) {
    // Python str.strip(): ASCII whitespace set == sa_core::str::trim.
    return str::trim(s);
}

// ---------------------------------------------------------------------------
// P2 快赢：进程级指纹缓存。
// 这里的读端点被 HTTP 线程高频调用（editor_env.json：AI 设置/语义路由/
// workshop_root 等；.editor_usage.json：usage_store），每次全量读盘+解析是
// 纯浪费。缓存模型与 cfg_cache 的表缓存一致：
//   * 键 = 绝对路径（本模块经手的文件就是 editor_env.json / .editor_usage.json
//     这一小簇，map 基数恒定极小）；
//   * 指纹 = (mtime_ns, size)：外部任何写（原子替换、就地改写）都会改变其中
//     之一，指纹未变即视为内容未变，直接复用上次解析结果；
//   * 只有「成功解析出对象」的结果才进缓存。缺失/坏 UTF-8/坏 JSON/非对象/
//     空文件仍每次现读现判，与无缓存行为逐字节一致（也避免把失败态钉进缓存）；
//   * 写路径 atomic_merge_write 成功后显式失效，不依赖 mtime 时钟粒度。
// 线程安全：读端点可能来自 httpd 线程池的多个并发 worker（CLI 场景则是单
// 线程），用一把最简 mutex 保护这张小 map；临界区只有查/插 map 加一次
// json 拷贝，无需读写锁。
struct FingerprintEntry {
    long long mtime_ns = 0;
    long long size = 0;
    std::shared_ptr<const nlohmann::ordered_json> data;
};
std::mutex g_fp_mu;
std::map<std::string, FingerprintEntry> g_fp_cache;

}  // namespace

nlohmann::ordered_json read_json_file(const std::string& path) {
    // 指纹命中：零读盘零解析，返回缓存副本（对外仍按值返回，接口不变）。
    const auto st = paths::stat(path);
    if (st) {
        std::lock_guard<std::mutex> lk(g_fp_mu);
        auto it = g_fp_cache.find(path);
        if (it != g_fp_cache.end() && it->second.mtime_ns == st->mtime_ns &&
            it->second.size == st->size) {
            return *it->second.data;
        }
    }
    auto raw = paths::read_bytes(path);
    if (!raw) return nlohmann::ordered_json::object();
    auto text = decode_utf8_sig_strict(*raw);  // utf-8-sig; invalid -> nullopt
    if (!text) return nlohmann::ordered_json::object();
    std::string body = strip_ws(*text);
    if (body.empty()) return nlohmann::ordered_json::object();  // "" -> {}
    auto parsed = nlohmann::ordered_json::parse(body, nullptr, false);
    if (parsed.is_discarded() || !parsed.is_object()) {
        return nlohmann::ordered_json::object();  // loads() raise / non-dict -> {}
    }
    // 成功才缓存。stat 与 read 之间若文件刚被替换，存的 (旧指纹, 新内容) 组合
    // 也不会污染后续读取：下次 stat 指纹必与旧值不同 -> 强制 miss 回源。
    if (st) {
        std::lock_guard<std::mutex> lk(g_fp_mu);
        g_fp_cache[path] = FingerprintEntry{
            st->mtime_ns, st->size,
            std::make_shared<const nlohmann::ordered_json>(parsed)};
    }
    return parsed;
}

std::string env_path(const std::string& editor_root) {
    return paths::join(editor_root, "editor_env.json");
}

nlohmann::ordered_json read_editor_env(const std::string& editor_root) {
    return read_json_file(env_path(editor_root));
}

std::string read_workshop_override(const std::string& editor_root) {
    auto data = read_editor_env(editor_root);
    auto it = data.find("workshop_root");
    if (it == data.end() || !it->is_string()) return {};
    return strip_ws(it->get<std::string>());
}

nlohmann::ordered_json atomic_merge_write(const std::string& path,
                                          const nlohmann::ordered_json& extra) {
    // env_store.py:96 _WRITE_LOCK：读-合并-写整体串行，否则并发 HTTP 端点的
    // 后写者会用读过时的快照覆盖对方刚写入的键。
    static std::mutex write_lock;
    std::lock_guard<std::mutex> lk(write_lock);
    auto merged = read_json_file(path);
    if (extra.is_object()) {
        for (auto it = extra.begin(); it != extra.end(); ++it) {
            merged[it.key()] = it.value();  // existing keys keep their position
        }
    }
    write_text_atomic(path, py_dumps_indent(merged));
    {
        // P2：写成功后显式失效指纹缓存 —— 即便新文件 mtime/size 因时钟粒度
        // 未变，下次读取也强制回源，写读一致性不依赖指纹模型。
        std::lock_guard<std::mutex> lk_fp(g_fp_mu);
        g_fp_cache.erase(path);
    }
    return merged;
}

nlohmann::ordered_json merge_editor_env(const std::string& editor_root,
                                        const nlohmann::ordered_json& extra) {
    return atomic_merge_write(env_path(editor_root), extra);
}

}  // namespace env_store
}  // namespace sa_core
