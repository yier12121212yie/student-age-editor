// upload_staging: shared staging for the 网页版 M0.5 base64 zip uploads.
//
// A browser has no local filesystem path to hand the backend, so the web
// install flows POST the zip itself as JSON `{filename, data_base64}`. Both
// new routes — /api/plugins/install_upload and
// /api/resource_packs/import_upload — stage the decoded bytes to a temp file
// and then run the exact same pipeline as their --path siblings
// (install_plugin_from_path / rp::install_pack_from_path), so every
// validation error (bad manifest, corrupt zip, reserved id, ...) answers with
// the same 400 text the desktop flow produces.
//
// Contract notes:
//   * Decoded cap 100 MB (the plan's upload limit; httpd's transport envelope
//     is 256 MiB of wire body, see kMaxBodyBytes in httpd.cpp).
//   * base64 decoding is b64_decode_loose — Python
//     `base64.b64decode(data)` with validate=False (fs_tools.write_file
//     parity: whitespace/newlines tolerated, non-alphabet skipped).
//   * The temp file name is ASCII-only and unique per call (never derived
//     from `filename`, so a hostile name cannot escape the temp dir); the
//     caller-supplied filename is only forwarded to the install pipeline
//     after stripping path separators.
//   * Only transport errors are answered here (400/413/500). Install errors
//     propagate to the route's existing PyValueError -> 400 mapping.
#pragma once

#include <atomic>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <functional>
#include <string>

#include "p3b_support.h"  // b64_decode_loose
#include "server/httpd.h" // Req/Resp/Resp::Json, sa::json

namespace sa::upload {

// Decoded-bytes ceiling for one upload. 默认 100MB；可经环境变量
// EDITOR_MAX_UPLOAD_BYTES（字节）配置——网关按 gateway.json 的 max_body_bytes
// 给每个 backend 实例注入（见 gw_pool.cpp），以便托管环境放开大模组包上传。
inline size_t max_upload_bytes() {
    static const size_t cap = [] {
        const char* v = std::getenv("EDITOR_MAX_UPLOAD_BYTES");
        if (v && *v) {
            try {
                long long n = std::stoll(v);
                if (n > 0) return static_cast<size_t>(n);
            } catch (...) {
            }
        }
        return static_cast<size_t>(100ull * 1024 * 1024);
    }();
    return cap;
}

// wire cap: base64 inflates by 4/3; reject before decoding anything.
inline size_t max_base64_bytes() { return (max_upload_bytes() / 3 + 1) * 4; }

// Strip path separators so `filename` can never carry directory components.
inline std::string sanitize_filename(const std::string& name) {
    auto pos = name.find_last_of("/\\");
    return pos == std::string::npos ? name : name.substr(pos + 1);
}

// Decode `req.body` as {"filename"?, "data_base64"} and pass the staged temp
// zip to `install(path, filename)`; its return value goes out as 200 JSON.
inline Resp install_from_upload(
    const Req& req,
    const std::function<json(const std::string&, const std::string&)>& install,
    const char* fallback_filename) {
    // req.body 已由传输层解析（null=无体；{"_raw":...}=非 JSON 体）——直接取用。
    if (!req.body.is_object() || req.body.contains("_raw"))
        return Resp::Json(400, json{{"error", "invalid JSON body"}});
    const json& body = req.body;

    const std::string b64 = body.value("data_base64", std::string());
    if (b64.empty())
        return Resp::Json(400, json{{"error", "data_base64 required"}});
    if (b64.size() > max_base64_bytes())
        return Resp::Json(413, json{{"error", "zip too large (decoded cap " +
                                                  std::to_string(max_upload_bytes() / (1024 * 1024)) +
                                                  "MB)"}});

    auto decoded_opt = p3b::b64_decode_loose(b64);
    if (!decoded_opt || decoded_opt->empty())
        return Resp::Json(400, json{{"error", "data_base64 is not valid base64"}});
    std::string decoded = std::move(*decoded_opt);
    if (decoded.size() > max_upload_bytes())
        return Resp::Json(413, json{{"error", "zip too large (decoded cap " +
                                                  std::to_string(max_upload_bytes() / (1024 * 1024)) +
                                                  "MB)"}});

    std::string filename = sanitize_filename(body.value("filename", std::string()));
    if (filename.empty()) filename = fallback_filename;

    // Unique ASCII temp name; /tmp or %TEMP% must exist (both always do on
    // every supported platform, same assumption as Python's tempfile usage).
    static std::atomic<unsigned long long> seq{0};
    const std::string name = "editor_upload_" + std::to_string(time(nullptr)) + "_" +
                             std::to_string(seq.fetch_add(1)) + ".zip";
    const std::filesystem::path staged =
        std::filesystem::temp_directory_path() / name;
    {
        std::ofstream f(staged, std::ios::binary);
        if (!f) return Resp::Json(500, json{{"error", "cannot write temp file"}});
        f.write(decoded.data(), static_cast<std::streamsize>(decoded.size()));
    }
    struct Remover {
        const std::filesystem::path& p;
        ~Remover() { std::error_code ec; std::filesystem::remove(p, ec); }
    } rm{staged};

    return Resp::Json(200, install(staged.string(), filename));
}

}  // namespace sa::upload
