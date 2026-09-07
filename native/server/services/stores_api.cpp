// stores_api.cpp —— 见 stores_api.h 的接缝说明（主代理专属）。
#include "server/services/stores_api.h"

#include <mutex>

namespace sa {
namespace {

// 默认空对象：available()==false，一切查询返回空——与 Python
// `if base is None: return frozenset()` 的降级语义一致（api.py:609-617）。
class EmptyBaseStore : public BaseStoreApi {
public:
    bool available() const override { return false; }
    std::shared_ptr<const std::set<int64_t>> table_ids(const std::string&) const override {
        return std::make_shared<const std::set<int64_t>>();
    }
    std::shared_ptr<const nlohmann::ordered_json> table(const std::string&) const override {
        static const auto kEmpty = std::make_shared<const nlohmann::ordered_json>(
            nlohmann::ordered_json::object());
        return kEmpty;
    }
    std::vector<std::string> loaded_tables() const override { return {}; }
};

std::mutex g_mu;
std::shared_ptr<const BaseStoreApi> g_store;  // null => use shared_empty()

std::shared_ptr<const BaseStoreApi> shared_empty() {
    static const std::shared_ptr<const BaseStoreApi> kEmpty =
        std::make_shared<const EmptyBaseStore>();
    return kEmpty;
}

}  // namespace

void register_base_store(std::shared_ptr<const BaseStoreApi> store) {
    std::lock_guard<std::mutex> lk(g_mu);
    g_store = std::move(store);
}

std::shared_ptr<const BaseStoreApi> base_store() {
    // 注册是一次性启动动作；每次拷贝出 shared_ptr 再解锁外使用，读侧永不见半更新。
    std::lock_guard<std::mutex> lk(g_mu);
    return g_store ? g_store : shared_empty();
}

}  // namespace sa
