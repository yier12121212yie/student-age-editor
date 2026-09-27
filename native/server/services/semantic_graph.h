// wip/P1/semantic_graph.h — 只读分析端点（图/解析三族）：
//   POST /api/effect/parse    文本 → 逐行结构化（模板/槽位/嵌套），文本语义与
//                             /api/effect_validate 一致；
//   GET  /api/graph/relations mod+本体合并数据里的人物关系（nodes/levels/edges）；
//   GET  /api/graph/timeline  带时间约束的事件/行动 → 回合索引（rounds/items）。
// 注册函数由 semantic_routes.cpp 的 register_semantic_routes 尾部调用（不改
// api_router.cpp）。全部只读，不触碰任何写路径。
#pragma once
#include "server/httpd.h"
namespace sa {
void register_semantic_graph(Router& r);
}  // namespace sa
