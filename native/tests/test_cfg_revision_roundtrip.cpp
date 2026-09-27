// tests/test_cfg_revision_roundtrip.cpp — 路由级回归：写成功响应必须回带新 revision
// （cfg_routes.cpp 阶段 2d「假冲突修复」）。
//
// 契约（前端 SaveService 批量保存链路依赖）：
//   1. PUT 全量写成功（200）响应 env 含 "revision"，且是写后立即重算的新指纹
//      （invalidate_cache + compute_revision_cached 的实际效果）。
//   2. 同一批量保存的第二张表：携带第一张表响应回带的 revision 再次 PUT，
//      verify 必须通过（修复前响应无该字段，前端只能继续用旧指纹 → 必 409
//      假冲突）。patch 分支同样回带该字段。
//   3. 校验仍是活的：用过期的旧 revision 重放 PUT 必须 409 revision_mismatch，
//      且 current_revision 与服务端 GET /api/workspace/revision 一致。
// 全程走 sat::call_router（同 test_s1_read_exit 的进程内黑盒），不直接调
// revision_manager。
#include <catch_amalgamated.hpp>

#include <string>

#include "test_support.h"

using sa::json;
using sat::call_router;
using sat::CfgFixture;

namespace {

// 从 200 响应里取 revision 字段，字段缺失直接 FAIL（回归点 1）。
std::string revision_of(const sa::Resp& r, const char* where) {
    const json& env = r.json_payload;
    INFO(where);
    REQUIRE(env.contains("revision"));
    REQUIRE(env.at("revision").is_string());
    return env.at("revision").get<std::string>();
}

}  // namespace

TEST_CASE("cfg routes: PUT 成功响应回带新 revision，第二张表携带它连发不再假冲突",
          "[cfg][revision][routes]") {
    CfgFixture fx("cfg_rev_roundtrip");
    fx.write_cfg_file("TalkCfg", R"({"1":{"id":1}})");
    fx.write_cfg_file("EvtCfg", R"({"1":{"id":1}})");

    // 起点：GET /api/workspace/revision 拿基线指纹（rev0）。
    auto g0 = call_router(fx.router(), "GET", "/api/workspace/revision");
    REQUIRE(g0.status == 200);
    REQUIRE(g0.json_payload.contains("revision"));
    const std::string rev0 = g0.json_payload.at("revision").get<std::string>();
    REQUIRE_FALSE(rev0.empty());

    // PUT 表一（TalkCfg 全量写）携 rev0：verify 通过，200 响应必须含新 revision
    // 且不等于 rev0（写一张表必换指纹）。
    json body1;
    body1["data"] = json{{"1", json{{"id", 1}, {"v", 10}}}};
    body1["revision"] = rev0;
    auto w1 = call_router(fx.router(), "PUT", "/api/cfg/TalkCfg", {}, body1);
    REQUIRE(w1.status == 200);
    const std::string rev1 = revision_of(w1, "first full-write PUT");
    CHECK(rev1 != rev0);

    // 关键回归：第二张表（EvtCfg）携 rev1 连发——修复前必 409（假冲突），
    // 现在 verify 通过并回带自己的新指纹 rev2。
    json body2;
    body2["data"] = json{{"1", json{{"id", 1}, {"v", 20}}}};
    body2["revision"] = rev1;
    auto w2 = call_router(fx.router(), "PUT", "/api/cfg/EvtCfg", {}, body2);
    INFO("second PUT status=" << w2.status);
    REQUIRE(w2.status == 200);
    const std::string rev2 = revision_of(w2, "second full-write PUT");
    CHECK(rev2 != rev1);

    // patch 分支（do_cfg_patch）同样回带：用 rev2 对 TalkCfg 发 patch，200 且
    // 新指纹再次变化。
    json body3;
    body3["patch"] = json{{"set", json{{"7", json{{"id", 7}, {"v", 30}}}}}};
    body3["revision"] = rev2;
    auto w3 = call_router(fx.router(), "PUT", "/api/cfg/TalkCfg", {}, body3);
    REQUIRE(w3.status == 200);
    const std::string rev3 = revision_of(w3, "patch PUT");
    CHECK(rev3 != rev2);

    // 响应字段与服务端口径一致：写后 GET 到的就是最后回带的 rev3
    // （证明响应里那份不是脏缓存，invalidate 生效）。
    auto g1 = call_router(fx.router(), "GET", "/api/workspace/revision");
    REQUIRE(g1.status == 200);
    CHECK(g1.json_payload.at("revision").get<std::string>() == rev3);

    // 校验仍是活的：重放过期指纹 rev0 → 409 revision_mismatch，且 409 里
    // 的 current_revision 与服务端当前一致（rev3）。
    json body4;
    body4["data"] = json{{"1", json{{"id", 1}, {"v", 99}}}};
    body4["revision"] = rev0;
    auto w4 = call_router(fx.router(), "PUT", "/api/cfg/TalkCfg", {}, body4);
    REQUIRE(w4.status == 409);
    CHECK(w4.json_payload.value("reason", "") == "revision_mismatch");
    CHECK(w4.json_payload.value("current_revision", "") == rev3);
}
