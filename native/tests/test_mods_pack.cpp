// 网页版模组上传/下载 —— [modspack] 黑盒路由级单测。
//   POST /api/mods/export       当前/指定模组 -> store-only zip（base64）
//   POST /api/mods/import_path  本机 zip 路径导入
//   POST /api/mods/import_upload 网页版 {filename, data_base64} 导入
// 覆盖：打包往返、顶层目录剥离、manifest 回填、非法条目/缺内容/缺体拒绝、导入后
// 自动选中。
#include <catch_amalgamated.hpp>

#include <filesystem>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

#include "sa_core/json_wire.h"
#include "sa_core/paths.h"
#include "server/services/p3b_support.h"
#include "server/services/zip_store_writer.h"
#include "test_support.h"

using json = sa::json;
using sat::call_router;

namespace {

struct ModsPackFixture : sat::CfgFixture {
    ModsPackFixture() : sat::CfgFixture("modspack") {}
};

std::string b64(const std::string& raw) { return sa::p3b::b64_encode(raw); }

std::string make_zip(const std::vector<std::pair<std::string, std::string>>& files) {
    std::vector<sa::zipstore::Entry> entries;
    entries.reserve(files.size());
    for (const auto& kv : files) entries.push_back({kv.first, kv.second});
    std::string out;
    bool ok = sa::zipstore::build(entries, out);
    REQUIRE(ok);
    return out;
}

sa::Resp import_upload(sa::Router& r, const std::string& zip, const std::string& filename) {
    return call_router(r, "POST", "/api/mods/import_upload", {},
                       json{{"filename", filename}, {"data_base64", b64(zip)}});
}

}  // namespace

TEST_CASE("mods export: 当前模组打包为 zip（往返可读）", "[modspack]") {
    ModsPackFixture fx;
    fx.write_cfg_file("EvtCfg", R"({"1":{"id":1,"title":"t"}})");
    auto resp = call_router(fx.router(), "POST", "/api/mods/export", {}, json::object());
    REQUIRE(resp.status == 200);
    CHECK(resp.json_payload.value("filename", "") == "mod.zip");
    const std::string enc = resp.json_payload.value("data_base64", "");
    REQUIRE_FALSE(enc.empty());
    auto raw = sa::p3b::b64_decode_strict(enc);
    REQUIRE(raw.has_value());
    auto z = sa::p3b::ZipReader::open_bytes(*raw);
    REQUIRE(z.has_value());
    CHECK(z->has("Cfgs/zh-cn/EvtCfg.json"));
    auto content = z->read("Cfgs/zh-cn/EvtCfg.json");
    REQUIRE(content.has_value());
    CHECK(*content == R"({"1":{"id":1,"title":"t"}})");
}

TEST_CASE("mods export: 指定不存在的模组 -> 400", "[modspack]") {
    ModsPackFixture fx;
    auto resp = call_router(fx.router(), "POST", "/api/mods/export", {},
                            json{{"name", "nope"}});
    CHECK(resp.status == 400);
}

TEST_CASE("mods import_upload: 解包成新模组、回填 manifest、自动选中", "[modspack]") {
    ModsPackFixture fx;
    const std::string zip = make_zip({
        {"manifest.json", R"({"title":"我的模组"})"},
        {"Cfgs/zh-cn/EvtCfg.json", R"({"1":{"id":1}})"},
    });
    auto resp = import_upload(fx.router(), zip, "pack.zip");
    REQUIRE(resp.status == 200);
    CHECK(resp.json_payload.value("ok", false) == true);
    const std::string name = resp.json_payload["mod"].value("name", "");
    CHECK(name == "我的模组");
    CHECK(resp.json_payload["mod"].value("has_manifest", false) == true);
    const auto dir = fx.root() / std::filesystem::u8path(name);
    CHECK(std::filesystem::exists(dir / "Cfgs" / "zh-cn" / "EvtCfg.json"));
    CHECK(std::filesystem::exists(dir / "manifest.json"));
    // 导入后自动选中，方便界面直接切过去编辑。
    CHECK(sa::STATE().mod_name == name);
}

TEST_CASE("mods import_upload: 顶层目录被剥离", "[modspack]") {
    ModsPackFixture fx;
    const std::string zip = make_zip({
        {"MyMod/manifest.json", R"({"title":"FolderMod"})"},
        {"MyMod/Cfgs/zh-cn/TalkCfg.json", R"({"1":{"id":1}})"},
    });
    auto resp = import_upload(fx.router(), zip, "f.zip");
    REQUIRE(resp.status == 200);
    CHECK(resp.json_payload["mod"].value("name", "") == "FolderMod");
    CHECK(std::filesystem::exists(fx.root() / "FolderMod" / "Cfgs" / "zh-cn" / "TalkCfg.json"));
    CHECK_FALSE(std::filesystem::exists(fx.root() / "FolderMod" / "MyMod"));
}

TEST_CASE("mods import: 非法条目 / 缺内容 / 缺体 一律 400", "[modspack]") {
    ModsPackFixture fx;
    // '..' 穿越 -> 非法条目
    auto bad = import_upload(fx.router(), make_zip({{"../evil.txt", "x"}}), "e.zip");
    CHECK(bad.status == 400);
    // 无 manifest / 无 Cfgs/zh-cn -> 不是模组
    auto junk = import_upload(fx.router(), make_zip({{"readme.txt", "hello"}}), "j.zip");
    CHECK(junk.status == 400);
    // 缺 data_base64
    auto no_body = call_router(fx.router(), "POST", "/api/mods/import_upload", {},
                               json{{"filename", "x.zip"}});
    CHECK(no_body.status == 400);
    // 未落任何目录
    CHECK_FALSE(std::filesystem::exists(fx.root() / "我的模组"));
}

TEST_CASE("mods import_path: 本机 zip 路径导入", "[modspack]") {
    ModsPackFixture fx;
    const std::string zip = make_zip({
        {"manifest.json", R"({"title":"PathMod"})"},
        {"Cfgs/zh-cn/EvtCfg.json", R"({"1":{"id":1}})"},
    });
    const auto src = fx.root() / "src_pack.zip";
    {
        std::ofstream f(src, std::ios::binary);
        f.write(zip.data(), static_cast<std::streamsize>(zip.size()));
    }
    auto resp = call_router(
        fx.router(), "POST", "/api/mods/import_path", {},
        json{{"path", sa_core::paths::path_to_utf8(src)}, {"filename", "src_pack.zip"}});
    REQUIRE(resp.status == 200);
    CHECK(resp.json_payload["mod"].value("name", "") == "PathMod");
    CHECK(std::filesystem::exists(fx.root() / "PathMod" / "Cfgs" / "zh-cn" / "EvtCfg.json"));

    // 路径不存在 -> 400
    auto missing = call_router(fx.router(), "POST", "/api/mods/import_path", {},
                               json{{"path", sa_core::paths::path_to_utf8(fx.root() / "no.zip")}});
    CHECK(missing.status == 400);
}

// 回归：模组 zip 里的非 cfg 资源（贴图/配乐）必须原样落地；且资源名常常是非
// ASCII（中文贴图名），旧实现取父目录时走 std::filesystem::path(std::string)
// ——Windows 按 ANSI 代码页解释，非 ASCII 直接抛
// "No mapping for the Unicode character exists in the target multi-byte code page"
// 让整包上传失败；导出侧 generic_string() 还会把名字编成 GBK 乱码。这里一并
// 覆盖「带中文资源的导入 -> 导出 -> 再读」往返。
TEST_CASE("mods import/export: 非 cfg 资源（含非 ASCII 文件名）原样往返", "[modspack]") {
    ModsPackFixture fx;
    const std::string png =
        std::string("\x89PNG\r\n\x1a\n", 8) + std::string(64, '\x7f');  // 伪二进制资源
    const std::string wav = std::string("RIFF") + std::string(128, '\x01');
    const std::string title = "资源模组";
    const std::string zip = make_zip({
        {"manifest.json", std::string("{\"title\":\"") + title + "\"}"},
        {"Cfgs/zh-cn/EvtCfg.json", R"({"1":{"id":1}})"},
        {"Textures/贴图.png", png},
        {"Audios/配乐.wav", wav},
    });

    auto resp = import_upload(fx.router(), zip, "res.zip");
    REQUIRE(resp.status == 200);
    CHECK(resp.json_payload["mod"].value("name", "") == title);
    const auto dir = fx.root() / std::filesystem::u8path(title);
    const auto tex = dir / std::filesystem::u8path("Textures/贴图.png");
    const auto aud = dir / std::filesystem::u8path("Audios/配乐.wav");
    CHECK(std::filesystem::exists(tex));
    CHECK(std::filesystem::exists(aud));
    auto tex_raw = sa_core::paths::read_bytes(sa_core::paths::path_to_utf8(tex));
    REQUIRE(tex_raw.has_value());
    CHECK(*tex_raw == png);  // 二进制字节无损
    auto aud_raw = sa_core::paths::read_bytes(sa_core::paths::path_to_utf8(aud));
    REQUIRE(aud_raw.has_value());
    CHECK(*aud_raw == wav);

    // 导出：root 本身含中文目录名，旧实现 std::filesystem::path base(root) 同样抛错。
    auto exp = call_router(fx.router(), "POST", "/api/mods/export", {}, json{{"name", title}});
    REQUIRE(exp.status == 200);
    auto raw = sa::p3b::b64_decode_strict(exp.json_payload.value("data_base64", ""));
    REQUIRE(raw.has_value());
    auto z = sa::p3b::ZipReader::open_bytes(*raw);
    REQUIRE(z.has_value());
    CHECK(z->has("Textures/贴图.png"));  // 名字必须仍是可读 UTF-8，而非 GBK 乱码
    CHECK(z->has("Audios/配乐.wav"));
    auto ztex = z->read("Textures/贴图.png");
    REQUIRE(ztex.has_value());
    CHECK(*ztex == png);
}
