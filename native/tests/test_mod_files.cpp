// 网页版计划 M3 —— 本地资源文件导入端点 [modfiles] 黑盒路由级单测。
// POST /api/mod/import_files：图片/音频按扩展名归类落盘、文件名净化、重名不覆盖、
// 沙箱拒绝越界、坏 base64 与非法名进 errors（绝不 500）、音频可选登记 AudioCfg。
// 路由经 build_router() 全量挂载（api_router.cpp 已 register_mod_files_routes）；
// 这里照抄 test_p3a_content 的 CfgFixture + 显式 register 写法（双注册无害，
// Router 首命中优先）。
#include <catch_amalgamated.hpp>

#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "server/api_router.h"
#include "server/cfg_cache.h"
#include "server/services/mod_files_routes.h"
#include "server/services/p3b_support.h"
#include "test_support.h"

using json = sa::json;
using sat::call_router;

namespace {

struct ModFilesFixture : sat::CfgFixture {
    ModFilesFixture() : sat::CfgFixture("modfiles") { sa::register_mod_files_routes(router()); }
};

// 内联的极简 base64 编码（避免手抄 base64 出错；仅测试用）。
std::string b64(const std::string& raw) { return sa::p3b::b64_encode(raw); }

// 构造一个真实字节序列（模拟 1x1 PNG：PNG magic + 填充），内容本身不被解析，
// 归类只认扩展名；这里保证解码字节数与盘上内容可逐字节比对。
std::string fake_png_bytes() {
    std::string s;
    s.push_back(static_cast<char>(0x89));
    s += "PNG\r\n\x1a\n";
    s.append(40, static_cast<char>(0xAB));  // 固定 40 字节
    return s;                                // 8 + 40 = 48 字节
}

json file_obj(const std::string& name, const std::string& data_b64) {
    json o = json::object();
    o["name"] = name;
    o["data"] = data_b64;
    return o;
}

json file_obj(const std::string& name, const std::string& data_b64, const std::string& dir) {
    json o = file_obj(name, data_b64);
    o["dir"] = dir;
    return o;
}

json post_body(json files, bool register_audio = false) {
    json b = json::object();
    b["files"] = std::move(files);
    b["register_audio"] = register_audio;
    return b;
}

std::optional<std::string> read_file(const std::filesystem::path& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return std::nullopt;
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

sa::Resp import_files(sa::Router& r, const json& files, bool register_audio = false) {
    return call_router(r, "POST", "/api/mod/import_files", {}, post_body(files, register_audio));
}

}  // namespace

TEST_CASE("import_files: 未选择模组 -> 400", "[modfiles]") {
    ModFilesFixture fx;
    auto& r = fx.router();
    {  // 临时清空 mod_root 模拟“未选择模组”。
        std::lock_guard<std::mutex> lk(sa::STATE().mu_);
        sa::STATE().mod_root.clear();
    }
    auto resp = import_files(r, json::array({file_obj("a.png", b64("x"))}));
    CHECK(resp.status == 400);
    CHECK(resp.json_payload["error"] == "未选择模组");
}

TEST_CASE("import_files: files 非法 -> 400", "[modfiles]") {
    ModFilesFixture fx;
    auto& r = fx.router();
    // 缺 files。
    CHECK(call_router(r, "POST", "/api/mod/import_files", {}, json::object()).status == 400);
    // files 非数组。
    CHECK(call_router(r, "POST", "/api/mod/import_files", {},
                      json{{"files", json::object()}})
              .status == 400);
    // files 空数组。
    auto resp = import_files(r, json::array());
    CHECK(resp.status == 400);
}

TEST_CASE("import_files: 图片落 Textures + 目录前缀只取 basename", "[modfiles]") {
    ModFilesFixture fx;
    auto& r = fx.router();
    const std::string raw = fake_png_bytes();
    const std::string enc = b64(raw);

    json files = json::array();
    files.push_back(file_obj("C:\\x\\evil.png", enc));  // 反斜杠目录前缀
    files.push_back(file_obj("a/b.png", enc));          // 正斜杠目录前缀
    auto resp = import_files(r, files);
    REQUIRE(resp.status == 200);
    REQUIRE(resp.json_payload["saved"].size() == 2);
    CHECK(resp.json_payload["errors"].empty());

    const json& s0 = resp.json_payload["saved"][0];
    CHECK(s0["name"] == "C:\\x\\evil.png");            // 原名回显
    CHECK(s0["path"] == "Textures/evil.png");          // 只取 basename，归类 Textures
    CHECK(s0["size"] == static_cast<long long>(raw.size()));
    CHECK(s0["audio_id"].is_null());
    CHECK(s0["audio_error"].is_null());
    CHECK(resp.json_payload["saved"][1]["path"] == "Textures/b.png");

    // 盘上真实存在且字节逐等。
    auto on_disk = read_file(fx.mod_root() / "Textures" / "evil.png");
    REQUIRE(on_disk.has_value());
    CHECK(*on_disk == raw);
    CHECK(std::filesystem::file_size(fx.mod_root() / "Textures" / "b.png") == raw.size());
}

TEST_CASE("import_files: 重名不覆盖 -> name_1.ext", "[modfiles]") {
    ModFilesFixture fx;
    auto& r = fx.router();
    const std::string enc = b64(fake_png_bytes());
    auto resp1 = import_files(r, json::array({file_obj("shot.png", enc)}));
    REQUIRE(resp1.json_payload["saved"][0]["path"] == "Textures/shot.png");
    auto resp2 = import_files(r, json::array({file_obj("shot.png", enc)}));
    REQUIRE(resp2.json_payload["saved"][0]["path"] == "Textures/shot_1.png");
    auto resp3 = import_files(r, json::array({file_obj("shot.png", enc)}));
    REQUIRE(resp3.json_payload["saved"][0]["path"] == "Textures/shot_2.png");
    CHECK(std::filesystem::exists(fx.mod_root() / "Textures" / "shot.png"));
    CHECK(std::filesystem::exists(fx.mod_root() / "Textures" / "shot_1.png"));
    CHECK(std::filesystem::exists(fx.mod_root() / "Textures" / "shot_2.png"));
}

TEST_CASE("import_files: 音频 + register_audio -> Audios 落盘 + AudioCfg 登记", "[modfiles]") {
    ModFilesFixture fx;
    auto& r = fx.router();
    const std::string raw = std::string(24, 'M');
    auto resp = import_files(r, json::array({file_obj("song.mp3", b64(raw))}), /*register_audio=*/true);
    REQUIRE(resp.status == 200);
    REQUIRE(resp.json_payload["saved"].size() == 1);
    const json& s = resp.json_payload["saved"][0];
    CHECK(s["path"] == "Audios/song.mp3");
    CHECK(s["size"] == static_cast<long long>(raw.size()));
    CHECK(s["audio_error"].is_null());
    REQUIRE(s["audio_id"].is_number_integer());
    const long long aid = s["audio_id"].get<long long>();
    CHECK(aid >= 1);
    CHECK(std::filesystem::exists(fx.mod_root() / "Audios" / "song.mp3"));

    // AudioCfg.json 出现新行：url=Audios/song.mp3, type=0, name=stem "song"。
    sa::invalidate_mod_cfgs_cache();
    auto disc = read_file(fx.cfg_dir() / "AudioCfg.json");
    REQUIRE(disc.has_value());
    json ac = json::parse(*disc);
    const std::string key = std::to_string(aid);
    REQUIRE(ac.contains(key));
    CHECK(ac[key]["url"] == "Audios/song.mp3");
    CHECK(ac[key]["type"] == 0);
    CHECK(ac[key]["name"] == "song");
    CHECK(ac[key]["id"] == aid);
}

TEST_CASE("import_files: 恶意名/越界 dir 进 errors，不抛 500", "[modfiles]") {
    ModFilesFixture fx;
    auto& r = fx.router();
    const std::string enc = b64("hi");
    json files = json::array();
    files.push_back(file_obj("..", enc, "Textures"));    // 纯 ".." 净化后为空
    files.push_back(file_obj("", enc, "Textures"));      // 空名
    files.push_back(file_obj("<>:\"|?*", enc, "Textures"));  // 非法字符全灭
    files.push_back(file_obj("ok.png", enc, "../escape"));    // dir 穿越
    files.push_back(file_obj("ok.png", enc, "C:\\abs"));      // dir 绝对路径/盘符
    files.push_back(json{{"data", enc}});                     // 缺 name
    auto resp = import_files(r, files);
    CHECK(resp.status == 200);                              // 绝不该 500
    CHECK(resp.json_payload["saved"].empty());
    CHECK(resp.json_payload["errors"].size() == 6);
    // 未落任何盘。
    CHECK_FALSE(std::filesystem::exists(fx.mod_root() / "Textures"));
    CHECK_FALSE(std::filesystem::exists(fx.mod_root() / "escape"));
}

TEST_CASE("import_files: 坏 base64 -> errors 且不落盘", "[modfiles]") {
    ModFilesFixture fx;
    auto& r = fx.router();
    // 合法字符但长度不是 4 的倍数 -> b64_decode 失败 -> write_file 抛 ApiError。
    auto resp = import_files(r, json::array({file_obj("x.png", "AAAAA")}));
    CHECK(resp.status == 200);
    CHECK(resp.json_payload["saved"].empty());
    REQUIRE(resp.json_payload["errors"].size() == 1);
    CHECK(resp.json_payload["errors"][0]["name"] == "x.png");
    CHECK_FALSE(resp.json_payload["errors"][0]["error"].get<std::string>().empty());
    CHECK_FALSE(std::filesystem::exists(fx.mod_root() / "Textures" / "x.png"));
}

TEST_CASE("import_files: 未知扩展名无 dir -> errors；显式 dir 可导入", "[modfiles]") {
    ModFilesFixture fx;
    auto& r = fx.router();
    const std::string enc = b64("payload");
    auto resp = import_files(r, json::array({file_obj("notes.txt", enc)}));
    CHECK(resp.status == 200);
    CHECK(resp.json_payload["saved"].empty());
    REQUIRE(resp.json_payload["errors"].size() == 1);
    CHECK(resp.json_payload["errors"][0]["error"].get<std::string>().find("dir") !=
          std::string::npos);

    // 同内容给出显式单层 dir -> 成功落该目录。
    auto ok = import_files(r, json::array({file_obj("notes.txt", enc, "Docs")}));
    REQUIRE(ok.json_payload["saved"].size() == 1);
    CHECK(ok.json_payload["saved"][0]["path"] == "Docs/notes.txt");
    CHECK(std::filesystem::exists(fx.mod_root() / "Docs" / "notes.txt"));
}

TEST_CASE("import_files: register_audio=false 时音频不登记", "[modfiles]") {
    ModFilesFixture fx;
    auto& r = fx.router();
    auto resp = import_files(r, json::array({file_obj("clip.wav", b64("WAV"))}),
                             /*register_audio=*/false);
    REQUIRE(resp.json_payload["saved"].size() == 1);
    CHECK(resp.json_payload["saved"][0]["path"] == "Audios/clip.wav");
    CHECK(resp.json_payload["saved"][0]["audio_id"].is_null());
    CHECK_FALSE(std::filesystem::exists(fx.cfg_dir() / "AudioCfg.json"));
}
