// server/ai_dicts_route: GET /api/ai/dicts — orchestrator-added at wave-2 merge.
// Port of ai.py:1674-1684 + ai_domain_service.list_dicts/get_dict (656-714).
// Gap owner was "邻组" per the P3b report; implemented here against the P1
// dicts.json accessor so neither group's files needed surgery.
#pragma once

#include "server/httpd.h"

namespace sa {

void register_ai_dicts_route(Router& r);

}  // namespace sa
