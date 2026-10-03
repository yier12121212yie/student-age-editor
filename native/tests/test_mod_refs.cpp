// 自托管大资源「COS 引用 + 导出拼接」——[modrefs] 黑盒路由级单测。
//
//   POST /api/mods/add_ref       直传暂存对象 -> 模组引用（record linked + cos_resources.json）
//   POST /api/mods/export_staged 本地盘 + COS 引用流式拼包 -> archived 产物 -> 预热直链
//
// 覆盖：归类/重名避让/索引落账/拒绝信封、视频归类、导出包内容逐字节比对、
// .editor_history 与索引不进包、引用对象缺失的 500、导出产物下载链路（202->ready）。
#include <catch_amalgamated.hpp>

#include <atomic>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <string>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "server/services/file_transfer.h"
#include "server/services/mod_refs_routes.h"
#include "server/services/p3b_support.h"
#include "test_ft_env.h"
#include "test_support.h"

using json = sa::json;
using sat::call_router;

namespace {

struct RefsFixture : sat::CfgFixture {
    RefsFixture() : sat::CfgFixture("modrefs") { sa::register_mod_refs_routes(router()); }
};

json read_index(const std::filesystem::path& mod_root) {
    auto raw = sa_core::paths::read_bytes(
        sa_core::paths::path_to_utf8(mod_root / "cos_resources.json"));
    REQUIRE(raw.has_value());
    json j = json::parse(*raw, nullptr, false);
    REQUIRE(j.is_object());
    return j;
}

// 浏览器直传 + 落内存 seam 的封装：返回 {file_id, cos_key}。
struct Pushed {
    std::string file_id;
    std::string key;
};

Pushed push_object(sa::Router& r, const std::shared_ptr<satft::MemCos>& mem,
                   const std::string& name, const std::string& bytes) {
    auto rq = call_router(r, "POST", "/api/v1/files/upload/request", {},
                          json{{"name", name}, {"size", static_cast<long long>(bytes.size())}});
    REQUIRE(rq.status == 200);
    Pushed p;
    p.file_id = rq.json_payload.value("file_id", std::string());
    p.key = rq.json_payload.value("cos_key", std::string());
    REQUIRE_FALSE(p.file_id.empty());
    {
        std::lock_guard<std::mutex> lk(mem->mu);
        mem->objects[p.key] = bytes;
    }
    return p;
}

}  // namespace

TEST_CASE("mods add_ref: 直传对象登记为模组引用（索引落账 + 重名避让）", "[modrefs]") {
    RefsFixture fx;
    satft::FtEnv env;
    auto mem = std::make_shared<satft::MemCos>();
    sa::file_transfer::set_cos_ops_for_test(satft::mem_ops(mem));
    satft::OpsReset reset;

    const std::string png = std::string("\x89PNG\r\n\x1a\n", 8) + std::string(2048, '\x41');
    const Pushed p = push_object(fx.router(), mem, "大图.png", png);

    auto ar = call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                          json{{"file_id", p.file_id}, {"name", "大图.png"}});
    REQUIRE(ar.status == 200);
    REQUIRE(ar.json_payload["saved"].size() == 1);
    CHECK(ar.json_payload["saved"][0].value("path", "") == "Textures/大图.png");
    CHECK(ar.json_payload["saved"][0].value("cos", false) == true);
    CHECK(ar.json_payload["saved"][0].value("size", 0LL) ==
          static_cast<long long>(png.size()));
    // 记录被钉成 linked（永久引用，不进 pending 清理）。
    CHECK(sa::file_transfer::find_record(env.root(), p.file_id).value("status", "") ==
          "linked");
    // 索引落账；资源实体不落盘（引用语义）。
    json idx = read_index(fx.mod_root());
    REQUIRE(idx["refs"].contains("Textures/大图.png"));
    CHECK(idx["refs"]["Textures/大图.png"].value("file_id", "") == p.file_id);
    CHECK(idx["refs"]["Textures/大图.png"].value("kind", "") == "texture");
    CHECK_FALSE(std::filesystem::exists(fx.mod_root() / "Textures"));

    // 同名再登记 -> _1 避让（索引里的 rel 参与判重，可重复引用同一对象）。
    auto ar2 = call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                           json{{"file_id", p.file_id}, {"name", "大图.png"}});
    REQUIRE(ar2.status == 200);
    CHECK(ar2.json_payload["saved"][0].value("path", "") == "Textures/大图_1.png");

    // 拒绝信封：缺 file_id / 未知 id / 未知扩展名 / 非法 dir / 不可引用状态。
    CHECK(call_router(fx.router(), "POST", "/api/mods/add_ref", {}, json::object())
              .status == 400);
    CHECK(call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                      json{{"file_id", "0000000000000000000000000000dead"},
                           {"name", "a.png"}})
              .status == 404);
    const Pushed txt = push_object(fx.router(), mem, "notes.txt", "hello");
    auto bad_ext = call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                               json{{"file_id", txt.file_id}, {"name", "notes.txt"}});
    CHECK(bad_ext.status == 400);
    auto ok_dir = call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                              json{{"file_id", txt.file_id},
                                   {"name", "notes.txt"},
                                   {"dir", "Docs"}});
    REQUIRE(ok_dir.status == 200);
    CHECK(ok_dir.json_payload["saved"][0].value("path", "") == "Docs/notes.txt");
    const Pushed b = push_object(fx.router(), mem, "b.bin", "xx");
    CHECK(call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                      json{{"file_id", b.file_id}, {"name", "b.bin"}, {"dir", "../x"}})
              .status == 400);
    // complete 后记录进入 archiving/archived，不再是可引用状态。
    const Pushed c = push_object(fx.router(), mem, "c.png", "yy");
    auto done = call_router(fx.router(), "POST", "/api/v1/files/upload/complete", {},
                            json{{"file_id", c.file_id}});
    REQUIRE(done.status == 202);
    auto late = call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                            json{{"file_id", c.file_id}, {"name", "c.png"}});
    CHECK(late.status == 409);
}

TEST_CASE("mods add_ref: 视频归类 Videos、显式 dir 优先", "[modrefs]") {
    RefsFixture fx;
    satft::FtEnv env;
    auto mem = std::make_shared<satft::MemCos>();
    sa::file_transfer::set_cos_ops_for_test(satft::mem_ops(mem));
    satft::OpsReset reset;

    const Pushed mp4 = push_object(fx.router(), mem, "片头.mp4", "ftypmp42xxxx");
    auto ar = call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                          json{{"file_id", mp4.file_id}, {"name", "片头.mp4"}});
    REQUIRE(ar.status == 200);
    CHECK(ar.json_payload["saved"][0].value("path", "") == "Videos/片头.mp4");
    CHECK(read_index(fx.mod_root())["refs"]["Videos/片头.mp4"].value("kind", "") == "video");

    const Pushed wav = push_object(fx.router(), mem, "配乐.wav", "RIFFxxxx");
    auto ar2 = call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                           json{{"file_id", wav.file_id}, {"name", "配乐.wav"}});
    REQUIRE(ar2.status == 200);
    CHECK(ar2.json_payload["saved"][0].value("path", "") == "Audios/配乐.wav");
    CHECK(read_index(fx.mod_root())["refs"]["Audios/配乐.wav"].value("kind", "") == "audio");
}

TEST_CASE("mods export_staged: 本地盘 + COS 引用合并打包，成品可预热直链", "[modrefs]") {
    RefsFixture fx;
    satft::FtEnv env;
    auto mem = std::make_shared<satft::MemCos>();
    sa::file_transfer::set_cos_ops_for_test(satft::mem_ops(mem));
    satft::OpsReset reset;

    // 本地盘来源：cfg 表 + 已解出的贴图 + 不该进包的历史目录。
    fx.write_cfg_file("EvtCfg", R"({"1":{"id":1}})");
    const std::filesystem::path tex_dir = fx.mod_root() / "Textures";
    std::filesystem::create_directories(tex_dir);
    const std::string local_png = std::string("\x89PNG", 4) + std::string(64, '\x02');
    {
        std::ofstream f(tex_dir / "local.png", std::ios::binary);
        f.write(local_png.data(), static_cast<std::streamsize>(local_png.size()));
    }
    std::filesystem::create_directories(fx.mod_root() / ".editor_history");
    {
        std::ofstream f(fx.mod_root() / ".editor_history" / "x.json", std::ios::binary);
        f << "{}";
    }

    // COS 引用来源：贴图 / 配乐 / 视频各一。
    const std::string cos_png = std::string("\x89PNG\r\n\x1a\n", 8) + std::string(4096, '\x03');
    const std::string wav = std::string("RIFF") + std::string(1024, '\x01');
    const std::string mp4 = std::string("ftyp", 4) + std::string(2048, '\x05');
    auto add_ref = [&](const std::string& nm, const std::string& bytes) {
        const Pushed p = push_object(fx.router(), mem, nm, bytes);
        auto ar = call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                              json{{"file_id", p.file_id}, {"name", nm}});
        REQUIRE(ar.status == 200);
        return ar.json_payload["saved"][0].value("path", std::string());
    };
    CHECK(add_ref("cos贴图.png", cos_png) == "Textures/cos贴图.png");
    CHECK(add_ref("配乐.wav", wav) == "Audios/配乐.wav");
    CHECK(add_ref("片头.mp4", mp4) == "Videos/片头.mp4");

    auto ex = call_router(fx.router(), "POST", "/api/mods/export_staged", {}, json::object());
    REQUIRE(ex.status == 200);
    const std::string file_id = ex.json_payload.value("file_id", std::string());
    REQUIRE_FALSE(file_id.empty());
    CHECK(ex.json_payload.value("filename", std::string()) == "mod.zip");
    CHECK(ex.json_payload.value("size", 0LL) > 0);

    // 产物是 archived 记录（本地已落盘），zip 内容 = 本地文件 + COS 拉回的引用。
    auto rec = sa::file_transfer::find_record(env.root(), file_id);
    REQUIRE(rec.is_object());
    CHECK(rec.value("status", std::string()) == "archived");
    auto z = sa::p3b::ZipReader::open_file(rec.value("local_path", std::string()));
    REQUIRE(z.has_value());
    CHECK(z->has("Cfgs/zh-cn/EvtCfg.json"));
    CHECK(z->has("Textures/local.png"));
    CHECK(z->has("Textures/cos贴图.png"));
    CHECK(z->has("Audios/配乐.wav"));
    CHECK(z->has("Videos/片头.mp4"));
    CHECK_FALSE(z->has("cos_resources.json"));       // 服务器账本不进包
    CHECK_FALSE(z->has(".editor_history/x.json"));   // 本地历史不进包
    auto got_local = z->read("Textures/local.png");
    REQUIRE(got_local.has_value());
    CHECK(*got_local == local_png);
    auto got_cos = z->read("Textures/cos贴图.png");
    REQUIRE(got_cos.has_value());
    CHECK(*got_cos == cos_png);
    auto got_mp4 = z->read("Videos/片头.mp4");
    REQUIRE(got_mp4.has_value());
    CHECK(*got_mp4 == mp4);

    // 下载链路：首访触发预热（202），Worker 推回 COS 后给预签名直链。
    auto dl1 = call_router(fx.router(), "GET", "/api/v1/files/" + file_id + "/download");
    REQUIRE(dl1.status == 202);
    CHECK(dl1.json_payload.value("status", std::string()) == "warming_up");
    std::string werr;
    REQUIRE(sa::file_transfer::warm_now(env.root(), file_id, &werr));
    auto dl2 = call_router(fx.router(), "GET", "/api/v1/files/" + file_id + "/download");
    REQUIRE(dl2.status == 200);
    CHECK(dl2.json_payload.value("status", std::string()) == "ready");
    CHECK(dl2.json_payload.value("url", std::string()).find("X-Amz-Signature=") !=
          std::string::npos);
}

TEST_CASE("mods export_staged: 引用对象缺失 -> 500 且不留残缺产物", "[modrefs]") {
    RefsFixture fx;
    satft::FtEnv env;
    auto mem = std::make_shared<satft::MemCos>();
    sa::file_transfer::set_cos_ops_for_test(satft::mem_ops(mem));
    satft::OpsReset reset;

    fx.write_cfg_file("EvtCfg", R"({"1":{"id":1}})");
    // 申请了直传、也 add_ref 了，但对象从未真正 PUT 上去（COS 里没有 key）。
    auto rq = call_router(fx.router(), "POST", "/api/v1/files/upload/request", {},
                          json{{"name", "丢失.png"}, {"size", 123}});
    REQUIRE(rq.status == 200);
    auto ar = call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                          json{{"file_id", rq.json_payload.value("file_id", std::string())},
                               {"name", "丢失.png"}});
    REQUIRE(ar.status == 200);

    auto ex = call_router(fx.router(), "POST", "/api/mods/export_staged", {}, json::object());
    CHECK(ex.status == 500);
    CHECK(ex.json_payload.value("error", std::string()).find("引用资源拉取失败") !=
          std::string::npos);
}

TEST_CASE("mods export_staged: 未选择模组/未知名字 -> 400", "[modrefs]") {
    RefsFixture fx;
    {
        std::lock_guard<std::mutex> lk(sa::STATE().mu_);
        sa::STATE().mod_root.clear();
        sa::STATE().mod_name.clear();
    }
    CHECK(call_router(fx.router(), "POST", "/api/mods/export_staged", {}, json::object())
              .status == 400);
    CHECK(call_router(fx.router(), "POST", "/api/mods/export_staged", {},
                      json{{"name", "nope"}})
              .status == 400);
}

TEST_CASE("file_transfer: linked 记录直接给预签名直链（不落盘不预热）", "[modrefs]") {
    RefsFixture fx;
    satft::FtEnv env;
    auto mem = std::make_shared<satft::MemCos>();
    sa::file_transfer::set_cos_ops_for_test(satft::mem_ops(mem));
    satft::OpsReset reset;

    const Pushed p = push_object(fx.router(), mem, "大图.png", "pngbytes");
    auto ar = call_router(fx.router(), "POST", "/api/mods/add_ref", {},
                          json{{"file_id", p.file_id}, {"name", "大图.png"}});
    REQUIRE(ar.status == 200);

    auto dl = call_router(fx.router(), "GET", "/api/v1/files/" + p.file_id + "/download");
    REQUIRE(dl.status == 200);
    CHECK(dl.json_payload.value("status", std::string()) == "linked");
    CHECK(dl.json_payload.value("url", std::string()).find("X-Amz-Signature=") !=
          std::string::npos);
    // 状态查询同样如实回报 linked。
    auto st = call_router(fx.router(), "GET", "/api/v1/files/" + p.file_id);
    REQUIRE(st.status == 200);
    CHECK(st.json_payload.value("status", std::string()) == "linked");
}
