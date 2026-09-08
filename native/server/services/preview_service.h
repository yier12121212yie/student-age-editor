// wip/P3a/preview_service.h —— 事件场景预览（port of server/preview_service.py）。
//
// 三缓存原样移植：_mod_fp_cache（mod 单表 + 指纹）、_table_cache（本体/包兜底
// 结果，无指纹——失效全靠 invalidate_cache）、_meta_cache/_meta_fp（合并元数据）。
// 本体侧读取经 sa::base_store() 接缝（P4 未注册时 available()==false，等价
// Python 无游戏本体：_load_aa_cfg/_load_pack_cfg 恒 None）。
//
// 线程规则（CONVENTIONS 6 精神）：缓存锁只护 map 操作，磁盘 IO 一律在锁外；
// 竞态最多造成重复解析一次，结果幂等。
#pragma once

#include <cstddef>
#include <memory>
#include <string>

#include "content_util.h"

namespace sa {
namespace preview {

using json = content::json;

// preview_service.preview_event(evt_id)。找不到事件/参数空 -> 抛 sa::SandboxError
// （路由转 400）；数据形态引发的 Python 异常等价物抛 sa::ApiError（带类型名，
// 路由转 500 "%s: %s"）。
json preview_event(const std::string& evt_id);

// preview_service.invalidate_cache()：三缓存全清。经
// sa::set_preview_invalidator_hook 在 cfg 写路径 / select_mod 上被调。
void invalidate_cache();

namespace test_hooks {
// 缓存观测口（接线实测用；只读计数，不暴露内容）。
std::size_t table_cache_size();
std::size_t mod_fp_cache_size();
bool meta_cached();
}  // namespace test_hooks

}  // namespace preview
}  // namespace sa
