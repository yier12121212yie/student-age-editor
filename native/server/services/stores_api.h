#pragma once
// stores_api.h —— 跨组只读接缝（主代理专属文件，波次 2 各子代理只读不改）。
//
// 动机：/api/validate 的 base_ids 比对（P1）与 /api/search/talk 的本体表检索
// （P3a）需要「游戏原版数据」，但其加载与产物消费归 P4（base_store）。并行开发
// 期间 P4 的实现尚不存在，故冻结本接口：P1/P3a 通过 base_store() 取用并容忍默认
// 空对象（语义 = Python STATE.base is None 时返回空集，api.py:609-617）；
// P4 在自己的文件里实现并在路由注册时 register_base_store() 接线。
//
// 语义对齐（Python 出处）：
//   * table_ids ≈ _base_table_ids（api.py:609-637，A13：按对象身份缓存 frozenset；
//     C++ 用 shared_ptr<const set> 天然防原地修改，实现方须自带缓存）
//   * table     ≈ STATE.base.data[cfg]（base_service 全表只读视图；缺失返回空 object）
//   * loaded_tables ≈ STATE.base_loaded（表名列表；/api/state 的 [:200] 切片由调用方做）

#include <cstdint>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace sa {

class BaseStoreApi {
public:
    virtual ~BaseStoreApi() = default;

    // 原版数据是否可用（等价 STATE.base 非 None 且已加载）。
    virtual bool available() const = 0;

    // 指定表的键 int64 化全集；表缺失/键非法跳过（Python 的 int(k) try 语义）。
    // 允许实现方永久缓存（A13）；返回 nullptr 或空集都按「无」处理。
    virtual std::shared_ptr<const std::set<int64_t>> table_ids(const std::string& cfg) const = 0;

    // 只读全表视图（{}/"320101" 键控 object）；绝不返回可写引用（G3/B1 语义）。
    virtual std::shared_ptr<const nlohmann::ordered_json> table(const std::string& cfg) const = 0;

    // 已加载的表名（升序，与 base_loaded 一致）。
    virtual std::vector<std::string> loaded_tables() const = 0;
};

// 注册实现（P4 于 register 时调用；线程安全，注册后读侧无锁）。
void register_base_store(std::shared_ptr<const BaseStoreApi> store);

// 取当前实现；未注册时返回空对象单例（available()==false，table() 恒空）。
std::shared_ptr<const BaseStoreApi> base_store();

}  // namespace sa
