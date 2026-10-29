#include <catch_amalgamated.hpp>

#include "test_support.h"
#include "server/api_router.h"
#include "server/httpd.h"
#include "server/state.h"

TEST_CASE("Surpass Features: Workshop Status and Cancel API", "[workshop]") {
    auto r = sa::build_router();

    // 1. GET /api/workshop/status
    auto status_resp = sat::call_router(r, "GET", "/api/workshop/status");
    CHECK(status_resp.status == 200);
    CHECK(status_resp.json_payload.contains("ready"));
    CHECK(status_resp.json_payload["ready"] == true);
    CHECK(status_resp.json_payload.contains("steam_detected"));

    // 2. POST /api/workshop/publish-cancel
    auto cancel_resp = sat::call_router(r, "POST", "/api/workshop/publish-cancel");
    CHECK(cancel_resp.status == 200);
    CHECK(cancel_resp.json_payload.contains("cancelled"));
    CHECK(cancel_resp.json_payload["cancelled"] == true);
}

TEST_CASE("Surpass Features: Semantic Linter Diagnostics & QuickFix", "[linter]") {
    auto r = sa::build_router();

    // 1. GET /api/linter/diagnose
    auto diag_resp = sat::call_router(r, "GET", "/api/linter/diagnose");
    CHECK(diag_resp.status == 200);
    CHECK(diag_resp.json_payload.contains("health_score"));
    CHECK(diag_resp.json_payload.contains("total_issues"));
    CHECK(diag_resp.json_payload.contains("issues"));
    CHECK(diag_resp.json_payload["issues"].is_array());

    // 2. POST /api/linter/quickfix with fix_all
    auto fix_resp = sat::call_router(r, "POST", "/api/linter/quickfix", {}, sa::json{{"fix_all", true}});
    CHECK(fix_resp.status == 200);
    CHECK(fix_resp.json_payload.contains("ok"));
    CHECK(fix_resp.json_payload["ok"] == true);
    CHECK(fix_resp.json_payload.contains("fixed_count"));
    CHECK(fix_resp.json_payload.contains("health_score"));
}
