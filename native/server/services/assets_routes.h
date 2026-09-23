// server/services/assets_routes.h — /api/assets/*（资源目录 + 标签云）。
//
// 这两个端点是**只读派生视图**，不新增任何产物、不写盘、无副作用：
//   * 数据源复用 /api/aa/* 已有的两个单例——游戏 aa_index.json（AaIndex）与
//     预解码资源包（DecodedPack）；两者都不可用时按 /api/aa/keys 的
//     empty-degradation 语义回 200 + 空目录（**不是** 500）。
//   * 标签由 TagService 现算（见 tag_service.h），因此 aa_index.json 仍是
//     v3 冻结契约，旧缓存与 golden 都不受影响。
//   * additive：不进 native/tests/contract/golden（与 /api/perf 同例）。
#pragma once

#include "server/httpd.h"

namespace sa {

void register_assets_routes(Router& r);

}  // namespace sa
