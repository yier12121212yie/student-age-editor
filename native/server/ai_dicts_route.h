// server/ai_dicts_route: GET /api/ai/dicts — orchestrator-added at wave-2 merge.
// Port of ai.py:1674-1684 + ai_domain_service.list_dicts/get_dict (656-714).
// Gap owner was "邻组" per the P3b report; implemented here against the P1
// dicts.json accessor so neither group's files needed surgery.
#pragma once

#include "server/httpd.h"

namespace sa {

void register_ai_dicts_route(Router& r);

// 字典视图：GET /api/ai/dicts 的实现体，暴露给 HTTP MCP 的 `get_game_dicts`
// 工具复用（同一份实现，避免「REST 与 MCP 两套字典语义漂移」）。
// 两者都会在未知字典名时抛 SandboxError。
namespace dicts_view {

// name 为空 == 列出全部字典（{"dicts":[...]}）。
json list_dicts();

// 单个字典的 id→名称对照；limit_raw 为 nullptr 或空串时取默认 30（上限 100）。
json get_dict(const std::string& name_raw, const std::string& q_raw,
              const std::string* limit_raw);

}  // namespace dicts_view

}  // namespace sa
