// wip/P3a/main.cpp —— backend_wip 入口：生产 server_main + 本组剧情/预览/
// 搜索/舞台路由（content_routes）。extra_routes 移植点见 tests/CMakeLists.txt
// SA_GROUP_WIP 说明与 CONVENTIONS 9。
#include "content_routes.h"
#include "server/api_router.h"

int main(int argc, char** argv) {
    return sa::server_main(argc, argv, [](sa::Router& r) { sa::register_content_routes(r); });
}
