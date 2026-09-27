// 本地资源文件导入 (网页版计划 M3) — see mod_files_routes.h for the contract.
//
// POST /api/mod/import_files 把前端选中的若干本地文件（base64 内联）写进当前
// 选中模组的资源目录，可选地把音频登记进 AudioCfg.json。逐文件处理、互不影响：
// 任何一个文件的解析/净化/沙箱/写盘失败都只落成该文件的 errors 条目，绝不抛出
// 500。整体只在“未选择模组”或“files 非法”时返回顶层 400。
//
// 落盘规则：
//   * 归类目录：图片 png/jpg/jpeg/webp/bmp -> Textures；音频 wav/mp3/ogg/m4a ->
//     Audios；其余扩展名且未显式给 dir -> 该文件进 errors（需显式 dir）。
//   * 文件名净化：只取 basename（去 '/' '\\'），剥离 Windows 非法字符
//     <>:"|?* 与控制符、去首尾空白、去尾部点号；净化后为空 -> errors。
//   * dir：显式给出时必须是单层目录名（不含 '/' '\\' ':'、非 '.'/'..'），否则
//     errors；用于拒绝目录穿越与绝对路径。
//   * 重名不覆盖：已存在则 name_1.ext、name_2.ext… 递增到不冲突为止。
//   * 写盘：p3b::write_file(mod_root, dir/name, base64, true) 经沙箱 resolve，
//     自动建父目录；base64 非法（ApiError）/ 越界（SandboxError）/ IO 失败均落
//     入该文件 errors（size 取解码后真实字节数）。
//   * 登记：register_audio=true 且为音频扩展、且已成功写盘时，调
//     tts_store::register_audio_cfg_url(cfg_dir(), rel(斜杠), stem)；抛
//     TtsStoreError 时该 saved 条目仍返回，audio_id=null、audio_error 带中文原因。
#include "mod_files_routes.h"

#include <cctype>
#include <string>
#include <vector>

#include "p3b_fs_tools.h"  // p3b::write_file / ext_of / resolve
#include "p4_util.h"       // p4::split_ext
#include "sa_core/paths.h"
#include "server/api_router.h"  // invalidate_preview_cache
#include "server/cfg_cache.h"   // invalidate_mod_cfgs_cache
#include "server/state.h"       // STATE, cfg_dir, SandboxError, truthy
#include "tts.h"                // tts_store::register_audio_cfg_url

namespace sa {
namespace {

// 归类用的扩展名集合（小写、无点）。
bool is_image_ext(const std::string& ext) {
    static const std::vector<std::string> kExts = {"png", "jpg", "jpeg", "webp", "bmp"};
    for (const auto& e : kExts)
        if (e == ext) return true;
    return false;
}
bool is_audio_ext(const std::string& ext) {
    static const std::vector<std::string> kExts = {"wav", "mp3", "ogg", "m4a"};
    for (const auto& e : kExts)
        if (e == ext) return true;
    return false;
}

// Windows 文件名非法字符（含分隔符，basename 后本不该出现，一并防御）。
bool is_forbidden_char(unsigned char c) {
    switch (c) {
        case '<': case '>': case ':': case '"': case '|': case '?': case '*':
        case '/': case '\\':
            return true;
        default:
            return false;
    }
}

// 把用户提供的原始文件名净化成可落盘的 basename：去目录段、剥离非法字符与控制
// 符、去首尾空白、去尾部点号。结果为空表示这个名字不可用。
std::string sanitize_name(const std::string& raw) {
    size_t sep = raw.find_last_of("/\\");
    std::string s = sep == std::string::npos ? raw : raw.substr(sep + 1);
    std::string out;
    for (unsigned char c : s) {
        if (c < 0x20 || c == 0x7F) continue;  // 控制符（含 \t\n\r）
        if (is_forbidden_char(c)) continue;   // <>:"|?*  与分隔符
        out.push_back(static_cast<char>(c));
    }
    // 去首尾 ASCII 空白（Python str.strip 的空白集）。
    size_t b = out.find_first_not_of(" \t\n\r\f\v");
    if (b == std::string::npos) return {};
    size_t e = out.find_last_not_of(" \t\n\r\f\v");
    out = out.substr(b, e - b + 1);
    // 去尾部点号（Windows 禁止以 '.' 结尾）。
    while (!out.empty() && out.back() == '.') out.pop_back();
    return out;
}

// dir 校验：非空、单层目录名、不含分隔符/盘符冒号、非 '.'/'..'。
bool valid_single_dir(const std::string& dir) {
    if (dir.empty()) return false;
    if (dir == "." || dir == "..") return false;
    for (unsigned char c : dir) {
        if (c == '/' || c == '\\' || c == ':') return false;
        if (c < 0x20 || c == 0x7F) return false;
        if (is_forbidden_char(c)) return false;
    }
    return true;
}

// item 里的字符串字段（缺失或非 string 返回 false）。
bool str_field(const json& obj, const char* key, std::string& out) {
    if (!obj.is_object()) return false;
    auto it = obj.find(key);
    if (it == obj.end() || !it->is_string()) return false;
    out = it->get<std::string>();
    return true;
}

Resp top400(std::string msg) { return Resp::Json(400, json{{"error", std::move(msg)}}); }

}  // namespace

void register_mod_files_routes(Router& r) {
    r.post(R"(/api/mod/import_files)", [](const Req& req) -> Resp {
        // 1. 模组必须已选择（STATE.mod_root 非空）。
        std::string root;
        {
            std::lock_guard<std::mutex> lk(STATE().mu_);
            root = STATE().mod_root;
        }
        if (root.empty()) return top400("未选择模组");

        // 2. files 必须是存在、非空的数组（body 非对象 / files 缺失或非数组 / 空
        //    数组一律 400；数组内的单个坏元素才逐条进 errors）。
        if (!req.body.is_object()) return top400("请求体必须是 JSON 对象");
        auto fit = req.body.find("files");
        if (fit == req.body.end() || !fit->is_array())
            return top400("未提供有效的 files 列表");
        const json& files = *fit;
        if (files.empty()) return top400("未选择任何文件");

        // 3. register_audio 开关（Python _truthy 语义：仅真 true / "true"）。
        bool register_audio = false;
        if (req.body.contains("register_audio")) register_audio = truthy(req.body.at("register_audio"));

        json saved = json::array();
        json errors = json::array();
        bool any_audio_registered = false;

        for (const json& item : files) {
            std::string orig;
            if (item.is_object()) str_field(item, "name", orig);
            auto push_err = [&](const std::string& reason) {
                json entry = json::object();
                entry["name"] = orig;
                entry["error"] = reason;
                errors.push_back(std::move(entry));
            };

            // 3a. 结构 / name / data。
            if (!item.is_object()) {
                push_err("文件项必须是对象");
                continue;
            }
            std::string b64;
            if (!str_field(item, "data", b64)) {
                push_err("缺少文件内容 data（base64）");
                continue;
            }
            const std::string safe = sanitize_name(orig);
            if (safe.empty()) {
                push_err("文件名非法或为空");
                continue;
            }

            // 3b. 扩展名 + 归类目录（显式 dir 优先，且必须单层合法）。
            std::string ext_with_dot = p3b::ext_of(safe);  // ".png" 小写 / ""
            std::string ext = ext_with_dot.empty() ? std::string() : ext_with_dot.substr(1);
            std::string dir_given;
            bool has_dir = str_field(item, "dir", dir_given);
            std::string dir;
            bool audio = is_audio_ext(ext);
            if (has_dir && !dir_given.empty()) {
                std::string d = dir_given;
                // 允许 dir 前后空白，净化后仍需单层合法。
                size_t b = d.find_first_not_of(" \t\n\r\f\v");
                size_t e = d.find_last_not_of(" \t\n\r\f\v");
                d = (b == std::string::npos) ? std::string() : d.substr(b, e - b + 1);
                if (!valid_single_dir(d)) {
                    push_err("dir 需为单层目录名（不得含路径分隔符、盘符或 ..）");
                    continue;
                }
                dir = d;
            } else if (is_image_ext(ext)) {
                dir = "Textures";
            } else if (audio) {
                dir = "Audios";
            } else {
                push_err("未知扩展名，需显式 dir");
                continue;
            }

            // 3c. 重名不覆盖：在 dir 下找未占用的 candidate（stem_N.ext 递增）。
            auto pr = p4::split_ext(safe);  // {stem, ".ext" 或 ""}
            const std::string stem = pr.first;
            const std::string extdot = pr.second;
            std::string candidate = safe;
            auto exists = [&](const std::string& rel) -> bool {
                try {
                    return sa_core::paths::is_file(p3b::resolve(root, rel));
                } catch (const SandboxError&) {
                    return false;  // 净化后不该越界；抛错交给写盘阶段处理
                }
            };
            int bump = 0;
            while (exists(dir + "/" + candidate)) {
                ++bump;
                candidate = stem + "_" + std::to_string(bump) + extdot;
            }
            const std::string rel = dir + "/" + candidate;  // 斜杠形式

            // 3d. 写盘（经 p3b 沙箱 resolve + base64 解码）。
            long long size = 0;
            try {
                json w = p3b::write_file(root, rel, b64, /*base64_mode=*/true);
                size = w.value("size", 0LL);
            } catch (const SandboxError& e) {
                push_err(std::string("路径越界：") + e.what());
                continue;
            } catch (const std::exception& e) {  // ApiError(base64) / FsError 等
                push_err(e.what());
                continue;
            }

            // 3e. 可选：音频登记进 AudioCfg。写盘已成功，登记失败不回滚文件。
            json audio_id = nullptr;
            json audio_error = nullptr;
            if (register_audio && audio) {
                const std::string saved_stem = p4::split_ext(candidate).first;
                try {
                    long long id = tts_store::register_audio_cfg_url(cfg_dir(), rel, saved_stem);
                    audio_id = id;
                    any_audio_registered = true;
                } catch (const TtsStoreError& e) {
                    audio_error = std::string("登记 AudioCfg 失败: ") + e.what();
                } catch (const std::exception& e) {
                    audio_error = std::string("登记 AudioCfg 失败: ") + e.what();
                }
            }

            json entry = json::object();
            entry["name"] = orig;
            entry["path"] = rel;
            entry["size"] = size;
            entry["audio_id"] = audio_id;
            entry["audio_error"] = audio_error;
            saved.push_back(std::move(entry));
        }

        // 4. 有新登记的 AudioCfg 行 -> 让下游派生视图（mod cfgs / preview）作废。
        if (any_audio_registered) {
            invalidate_mod_cfgs_cache();
            invalidate_preview_cache();
        }

        json out = json::object();
        out["saved"] = std::move(saved);
        out["errors"] = std::move(errors);
        return Resp::Json(200, std::move(out));
    });
}

}  // namespace sa
