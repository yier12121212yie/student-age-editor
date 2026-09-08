// wip/P4/test_p4_ai_image.cpp — OpenAI Images generate/edit + GitHub update
// check over a local httplib::Server mock; validation paths hit the function /
// route before any network. [p4].
#include <catch_amalgamated.hpp>

#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>

#include "test_support.h"
#include "p4_mock.h"
#include "sa_core/http_client.h"
#include "sa_core/json_wire.h"
#include "sa_core/strings.h"
#include "ai_image.h"

using namespace sa;
using sa_core::http::b64_encode;
using sa_core::http::b64_decode;

TEST_CASE("normalize_base_url: default / scheme add / trailing-slash strip", "[p4][image]") {
    CHECK(ai_image::normalize_base_url("") == "https://api.openai.com/v1");
    CHECK(ai_image::normalize_base_url("https://api.openai.com/v1/") == "https://api.openai.com/v1");
    CHECK(ai_image::normalize_base_url("api.example.com") == "https://api.example.com");
    CHECK(ai_image::normalize_base_url("http://127.0.0.1:9/v1") == "http://127.0.0.1:9/v1");
}

TEST_CASE("build_multipart: exact wire layout (fields + files + terminal boundary)",
          "[p4][image]") {
    std::string ct;
    std::string body = ai_image::build_multipart(
        "----B", {{"model", "gpt-image-2"}}, {{"image", "image.png", "image/png", "RAWDATA"}}, &ct);
    CHECK(ct == "multipart/form-data; boundary=----B");
    // Structural assertions on the wire layout:
    CHECK(body.rfind("------B\r\n", 0) == 0);
    CHECK(body.find("Content-Disposition: form-data; name=\"model\"\r\n\r\n") != std::string::npos);
    CHECK(body.find("\r\n------B\r\n") != std::string::npos);
    CHECK(body.find("name=\"image\"; filename=\"image.png\"") != std::string::npos);
    CHECK(body.find("Content-Type: image/png\r\n\r\nRAWDATA\r\n") != std::string::npos);
    CHECK(sa_core::str::ends_with(body, "------B--\r\n"));
}

TEST_CASE("generate: validation before network (key/prompt/n/size)", "[p4][image]") {
    CHECK_THROWS_AS(ai_image::generate_images("", "", "", "x", 1, "", "", "", ""), ImageGenError);
    CHECK_THROWS_AS(ai_image::generate_images("sk", "", "", "", 1, "", "", "", ""), ImageGenError);
    CHECK_THROWS_AS(ai_image::generate_images("sk", "", "", "x", "many", "", "", "", ""),
                    ImageGenError);
    // gpt-image size must be a 64-multiple; 999x999 is not.
    CHECK_THROWS_AS(ai_image::generate_images("sk", "", "", "x", 1, "999x999", "", "", ""),
                    ImageGenError);
    // auto + valid sizes accepted up to request build (network -> will throw
    // connection here since base is unroutable, which is NOT ImageGenError-on-validation).
    CHECK_THROWS_AS(ai_image::generate_images("sk", "http://127.0.0.1:1", "", "x", 1, "1024x1024",
                                              "", "", ""),
                    ImageGenError);  // connection error surfaces as ImageGenError too
}

TEST_CASE("generate: b64_json response + url->base64 download", "[p4][image][mock]") {
    p4mock::Server srv;
    std::mutex mu;
    std::string last_auth, last_ctype;
    srv.server().Post(R"(/v1/images/generations)", [&](const httplib::Request& req, httplib::Response& res) {
        std::lock_guard<std::mutex> lk(mu);
        last_auth = req.get_header_value("Authorization");
        last_ctype = req.get_header_value("Content-Type");
        json out;
        out["model"] = "gpt-image-2";
        out["created"] = 123;
        out["data"] = json::array({json{{"b64_json", b64_encode("\x89PNGbytes")}}});
        res.set_content(sa_core::py_dumps(out), "application/json");
    });
    srv.server().Get(R"(/p.png)", [&](const httplib::Request&, httplib::Response& res) {
        res.set_content("RAWDATA", "image/png");
    });
    // url form
    srv.server().Post(R"(/v2/images/generations)", [&](const httplib::Request&, httplib::Response& res) {
        json out;
        out["model"] = "gpt-image-2";
        out["data"] = json::array({json{{"url", srv.base() + "/p.png"}}});
        res.set_content(sa_core::py_dumps(out), "application/json");
    });
    srv.start();

    auto r = ai_image::generate_images("sk-1", srv.base() + "/v1", "", "a cat", 1, "", "", "", "");
    CHECK(r["model"] == "gpt-image-2");
    CHECK(r["created"] == 123);
    REQUIRE(r["images"].size() == 1);
    std::string dec;
    REQUIRE(b64_decode(r["images"][0]["b64"].get<std::string>(), &dec));
    CHECK(dec == "\x89PNGbytes");
    CHECK(r["images"][0]["mime"] == "image/png");
    {
        std::lock_guard<std::mutex> lk(mu);
        CHECK(last_auth == "Bearer sk-1");
        CHECK(last_ctype == "application/json");
    }
    auto r2 = ai_image::generate_images("sk-1", srv.base() + "/v2", "", "a dog", 1, "", "", "", "");
    std::string dec2;
    REQUIRE(b64_decode(r2["images"][0]["b64"].get<std::string>(), &dec2));
    CHECK(dec2 == "RAWDATA");
    CHECK(r2["images"][0]["mime"] == "image/png");
}

TEST_CASE("edit: multipart POST carries image bytes + returns images", "[p4][image][mock]") {
    p4mock::Server srv;
    std::mutex mu;
    std::string last_ctype;
    bool got_image = false;
    bool got_prompt = false;
    std::string image_filename, image_content;
    srv.server().Post(R"(/v1/images/edits)", [&](const httplib::Request& req, httplib::Response& res) {
        std::lock_guard<std::mutex> lk(mu);
        last_ctype = req.get_header_value("Content-Type");
        // httplib parses a well-formed multipart body into req.files/req.params.
        auto f = req.files.find("image");
        got_image = f != req.files.end();
        if (got_image) {
            image_filename = f->second.filename;
            image_content = f->second.content;
        }
        auto pf = req.files.find("prompt");
        got_prompt = pf != req.files.end() && pf->second.content == "make it night";
        json out;
        out["model"] = "gpt-image-2";
        out["data"] = json::array({json{{"b64_json", b64_encode("EDITED")}}});
        res.set_content(sa_core::py_dumps(out), "application/json");
    });
    srv.start();
    auto r = ai_image::edit_image("sk-1", srv.base() + "/v1", "", "make it night",
                                  b64_encode("ORIGINALPNG"), "image/png", "", 1, "");
    REQUIRE(r["images"].size() == 1);
    std::string dec;
    b64_decode(r["images"][0]["b64"].get<std::string>(), &dec);
    CHECK(dec == "EDITED");
    {
        std::lock_guard<std::mutex> lk(mu);
        CHECK(sa_core::str::starts_with(last_ctype, "multipart/form-data; boundary=----studentage_aiedit_"));
        CHECK(got_image);                       // the server could parse our multipart
        CHECK(image_filename == "image.png");
        CHECK(image_content == "ORIGINALPNG");
        CHECK(got_prompt);
    }
    // validation: missing image / bad base64 / missing key.
    CHECK_THROWS_AS(ai_image::edit_image("sk", "", "", "p", "", "image/png", "", 1, ""), ImageGenError);
    CHECK_THROWS_AS(ai_image::edit_image("sk", "", "", "p", "!!!notb64!!!", "image/png", "", 1, ""),
                    ImageGenError);
    CHECK_THROWS_AS(ai_image::edit_image("", "", "", "p", b64_encode("x"), "image/png", "", 1, ""),
                    ImageGenError);
}

TEST_CASE("image routes: 400 error envelope for validation failures", "[p4][image][routes]") {
    Router r;
    register_ai_image_routes(r);
    auto gen = sat::call_router(r, "POST", "/api/ai/image/generate", {},
                                json{{"prompt", "x"}});
    CHECK(gen.status == 400);
    CHECK(std::string(gen.json_payload["error"]).find("API Key") != std::string::npos);
    auto gen2 = sat::call_router(r, "POST", "/api/ai/image/generate", {},
                                 json{{"api_key", "sk"}, {"prompt", "x"}, {"size", "999x999"}});
    CHECK(gen2.status == 400);
    CHECK(std::string(gen2.json_payload["error"]).find("size") != std::string::npos);
    auto ed = sat::call_router(r, "POST", "/api/ai/image/edit", {},
                               json{{"api_key", "sk"}, {"prompt", "p"}});
    CHECK(ed.status == 400);
    CHECK(std::string(ed.json_payload["error"]).find("image") != std::string::npos);
}

// ---- update_check --------------------------------------------------------

TEST_CASE("update version helpers", "[p4][update]") {
    CHECK(update_check::version_key("Alpha-v0.1") == (std::vector<long long>{0, 1}));
    CHECK(update_check::version_key("v1.4.1") == (std::vector<long long>{1, 4, 1}));
    CHECK(update_check::version_key("latest").empty());
    CHECK(update_check::line_prefix("Alpha-v0.1") == "Alpha-v");
    CHECK(update_check::line_prefix("v1.4.1") == "v");
    CHECK(update_check::same_release("v1.4.1", "V1.4.1"));
    CHECK_FALSE(update_check::same_release("v1.4.1", "v1.4.2"));
    // same line numeric: 0.10 > 0.9.
    CHECK(update_check::should_update("Alpha-v0.10", "Alpha-v0.9"));
    CHECK_FALSE(update_check::should_update("Alpha-v0.9", "Alpha-v0.10"));
    CHECK_FALSE(update_check::should_update("Alpha-v0.1", "Alpha-v0.1"));
    // cross line (different prefixes) -> not-same-release decides.
    CHECK(update_check::should_update("Alpha-v0.1", "1.4.1"));
    // latest has no numeric version -> never prompt.
    CHECK_FALSE(update_check::should_update("latest", "Alpha-v0.1"));
}

TEST_CASE("update_check via mock: newest-by-created release + assets + errors", "[p4][update][mock]") {
    p4mock::Server srv;
    srv.server().Get(R"(/gh)", [&](const httplib::Request&, httplib::Response& res) {
        json asset;
        asset["name"] = "a.zip";
        asset["browser_download_url"] = "http://dl/a.zip";
        asset["size"] = 10;
        json rel;
        rel["tag_name"] = "Alpha-v0.2";
        rel["name"] = "B";
        rel["created_at"] = "2026-01-01T00:00:00Z";
        rel["prerelease"] = true;
        rel["published_at"] = "2026-01-02T00:00:00Z";
        rel["html_url"] = "http://gh/r/0.2";
        rel["body"] = "notes";
        rel["assets"] = json::array();
        rel["assets"].push_back(asset);
        json draft;
        draft["tag_name"] = "newer-draft";
        draft["created_at"] = "2099-01-01";
        draft["draft"] = true;
        json arr = json::array();
        arr.push_back(rel);
        arr.push_back(draft);
        res.set_content(sa_core::py_dumps(arr), "application/json");
    });
    srv.server().Get(R"(/obj)", [&](const httplib::Request&, httplib::Response& res) {
        res.set_content(R"({"message":"rate limited"})", "application/json");
    });
    srv.server().Get(R"(/empty)", [&](const httplib::Request&, httplib::Response& res) {
        res.set_content("[]", "application/json");
    });
    srv.server().Get(R"(/404)", [&](const httplib::Request&, httplib::Response& res) {
        res.status = 404;
        res.set_content("nope", "text/plain");
    });
    srv.start();

    auto r = update_check::check_update(6, srv.base() + "/gh", "Alpha-v0.1");
    CHECK(r["ok"] == true);
    CHECK(r["latest_tag"] == "Alpha-v0.2");   // draft ignored despite later date
    CHECK(r["prerelease"] == true);
    CHECK(r["update_available"] == true);
    REQUIRE(r["assets"].size() == 1);
    CHECK(r["assets"][0]["url"] == "http://dl/a.zip");

    auto obj = update_check::check_update(6, srv.base() + "/obj", "Alpha-v0.1");
    CHECK(obj["ok"] == false);
    CHECK(std::string(obj["error"]).find("非列表") != std::string::npos);

    auto empty = update_check::check_update(6, srv.base() + "/empty", "Alpha-v0.1");
    CHECK(empty["ok"] == true);
    CHECK(empty["latest_tag"] == "");
    CHECK(empty["update_available"] == false);

    auto err = update_check::check_update(6, srv.base() + "/404", "Alpha-v0.1");
    CHECK(err["ok"] == false);
    CHECK(err["error"] == "HTTP 404");
}

TEST_CASE("update route (additive) returns the check_update dict", "[p4][update][mock][routes]") {
    p4mock::Server srv;
    srv.server().Get(R"(/gh)", [&](const httplib::Request&, httplib::Response& res) {
        json arr = json::array();
        arr.push_back(json{{"tag_name", "Alpha-v9.9"}, {"created_at", "2026-01-01"}});
        res.set_content(sa_core::py_dumps(arr), "application/json");
    });
    srv.start();
    Router r;
    register_update_routes(r);
    auto resp = sat::call_router(r, "GET", "/api/update/check",
                                 {{"url", srv.base() + "/gh"}, {"current", "Alpha-v0.1"}});
    REQUIRE(resp.status == 200);
    CHECK(resp.json_payload["latest_tag"] == "Alpha-v9.9");
    CHECK(resp.json_payload["update_available"] == true);
}
